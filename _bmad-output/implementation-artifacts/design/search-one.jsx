/* global React, ReactDOM */
// Search study — model "One menu" (tweak). One dropdown left of the field: the default search, Go to / Filter by,
// the configurations, Edit Configurations…. No Save — configurations are made and edited in the dialog only.
// The field holds one thing: nothing (= the default search, so you can type straight away), a typed search, or the
// name of a configuration. ✕ always returns to the default search. Go-to is one-shot: after the jump the field shows
// what the graph shows again.
(() => {
const { useState, useEffect, useRef, useMemo } = React;
const Ic = (p) => <window.Icon {...p}/>;
const RS = window.RevsetStore;
const { SCOPES, GO, FILTER, PRE, PRE_RE, scopeOf, textOf, labelOf, iconOf, nLabel, SIcon, Hl, buildIndex, suggest, compose, useRecents, setRecents, pushRecent } = window.GSKit;

const BNAME = { default: "jj log", all: "all()" };
const BDESC = { default: "Your mutable changes plus trunk context", all: "Every visible commit, incl. immutable history" };
const isB = (id) => RS.BUILTIN.some(b => b.id === id);
const Dollar = () => <span className="gs-dollar" aria-hidden="true">$</span>;
// which recent searches a scope shows while its field is still empty
const FITS = { any: () => true, change: (r) => r.k === "change", bookmark: () => false, author: (r) => r.k === "author" || r.k === "mine", file: (r) => r.k === "files", description: (r) => r.k === "description" };

function GraphSearchOne({ api, order = "saved", base = "all" }) {
  const configs = RS.useStore();
  const rec = useRecents();
  const home = RS.getHome();
  const active = RS.parseSearch(api.revset);
  const view = active ? null : api.revset;
  const atHome = !active && api.revset === home;
  const nameOf = (id) => BNAME[id] || (configs.find(c => c.id === id) || {}).name || "Unnamed";
  const [scope, setScope] = useState(() => active ? scopeOf(active) : "any");
  const [text, setText] = useState(() => active ? textOf(active) : "");
  const [focus, setFocus] = useState(false);
  const [pop, setPop] = useState(null);           // sugg · menu
  const [hi, setHi] = useState(0);
  const [editing, setEditing] = useState(false);
  const [, tick] = useState(0);
  const rootRef = useRef(null), inRef = useRef(null), listRef = useRef(null), menuRef = useRef(null);
  const focusRef = useRef(false), leaving = useRef(false), quiet = useRef(false), justFocused = useRef(false), pend = useRef(null);
  const ix = useMemo(() => buildIndex(api.all), [api.all]);
  const inView = useMemo(() => window.revsetMatch(api.revset), [api.revset, configs]);
  // a typed search replaces what the graph shows (all()) — or, tweak, runs inside the default search
  const inHome = base === "home" && home !== "all";
  const mk = (s) => ({ k: s.k, m: s.m, v: s.v, ci: s.ci, b: inHome ? home : undefined, w: inHome || undefined });
  const count = (s) => { const m = window.revsetMatch(RS.encodeSearch(mk(s))); return ix.commits.filter(m).length; };
  const savedExprs = useMemo(() => new Set(configs.map(c => RS.exprOf(c))), [configs]);
  const unsaved = (r) => !savedExprs.has(RS.searchExpr(mk(r)));
  const [narrow, setNarrow] = useState(() => window.matchMedia("(max-width: 980px)").matches);
  useEffect(() => { const m = window.matchMedia("(max-width: 980px)"), h = () => setNarrow(m.matches); m.addEventListener("change", h); return () => m.removeEventListener("change", h); }, []);
  const focusQuiet = () => { const i = inRef.current; if (!i) return; quiet.current = true; i.focus(); quiet.current = false; const n = i.value.length; i.setSelectionRange(n, n); };
  const revert = () => { setText(active ? textOf(active) : ""); setScope(active ? scopeOf(active) : "any"); };

  // the field follows the graph: a typed search shows as scope + text; a configuration or the default leaves the text empty
  useEffect(() => {
    const s = RS.parseSearch(api.revset);
    if (s) { setScope(scopeOf(s)); if (!focusRef.current) setText(textOf(s)); }
    else if (!focusRef.current) { setText(""); setScope("any"); }
  }, [api.revset]);
  // a configuration that no longer exists falls back to the default search
  useEffect(() => { if (!active && !isB(api.revset) && !configs.some(c => c.id === api.revset)) api.setRevset(home); }, [api.revset, configs, home]);
  // the active search follows the "runs in" tweak and a new default search
  useEffect(() => { if (!active) return; const n = RS.encodeSearch(mk(active)); if (n !== api.revset) api.setRevset(n); }, [api.revset, base, home]);
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
  }, [pop, q, scope, ix, configs, base, home]);
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

  // ---------- the one menu ----------
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
  const scopes = <>
    <div className="gs-gh"><span>Go to</span><em>selects a change · graph stays</em></div>
    {GO.map(sRow)}
    <div className="gs-gh"><span>Filter by</span><em>redraws the graph</em></div>
    {FILTER.map(sRow)}
  </>;
  const menu = () => (
    <div className="gs-scopes gs-one" role="listbox" aria-label="Search menu" onKeyDown={arrows} ref={menuRef}>
      {vRow(home, true)}
      {order === "saved"
        ? <>{rest.map(id => vRow(id))}<div className="gs-msep"></div>{scopes}</>
        : <><div className="gs-msep"></div>{scopes}{rest.length > 0 && <div className="gs-gh"><span>Configurations</span></div>}{rest.map(id => vRow(id))}</>}
      <div className="gs-msep"></div>
      <button className="gs-srow gs-edit" onClick={() => { close(); setEditing(true); }}>
        <span className="gs-ic"><Ic name="settings" size={13}/></span>
        <span className="gs-sl">Edit Configurations…</span>
      </button>
    </div>
  );

  // ---------- render ----------
  const sc = SCOPES[scope];
  const showView = !focus && !active && !atHome;   // at rest on a configuration: its name stands in the field
  const homeName = nameOf(home);
  const pillTitle = focus || active ? "Search in: " + sc.label + (sc.go ? " — selects a change" : scope === "any" ? "" : " — filters the graph") : atHome ? "Default search: " + homeName : "Showing " + nameOf(view);
  return (
    <div className={"gs is-one" + (focus ? " is-focus" : "") + (!atHome ? " has-q" : "")} ref={rootRef}>
      <button className={"gs-scope" + (showView || scope === "any" ? " is-any" : "") + (pop === "menu" ? " open" : "")} onClick={() => setPop(p => p === "menu" ? null : "menu")}
        aria-haspopup="listbox" aria-expanded={pop === "menu"} aria-label="Search menu" title={pillTitle}>
        {showView ? <Dollar/> : <><SIcon id={scope}/>{scope !== "any" && <span>{sc.label}</span>}</>}<Ic name="chevronDown" size={12}/>
      </button>
      <input ref={inRef} className={"gs-in" + (showView ? " is-val" + (isB(view) ? " mono" : "") : scope === "change" || scope === "file" ? " mono" : "")} value={text}
        placeholder={showView ? nameOf(view) : narrow ? sc.short || sc.ph : sc.ph} spellCheck="false" autoComplete="off"
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

Object.assign(window, { GraphSearchOne });
})();
