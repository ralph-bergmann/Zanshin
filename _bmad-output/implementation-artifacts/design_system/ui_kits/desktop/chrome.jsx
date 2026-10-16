// Chrome — everything that floats over the graph: the top bar (Place · View · Action) — the View capsule reads
// [search field] · gap legend · count · View options (search.jsx) — the project menu, the rail with its hover callouts and pinned panels.
(() => {
const { Island, IslandSeparator, IconButton, Button, GraphSearch, Popover, PopoverHeader, PopoverSeparator, OptionRow, OptionLink, Segmented, Switch, Slider,
  Callout, CalloutText, NamiMark, Icon, TrafficLights, ProjectMenu, GraphEdge } = window.ZanshinDesignSystem_a33847;

const ZK_RAIL = [
  { id: "bookmarks", label: "Bookmarks", icon: "branch" },
  { id: "reviews", label: "Reviews", icon: "reviews" },
  { id: "undo", label: "Undo Timeline", icon: "undo" },
];
const ZK_STATUS = { clean: "var(--proj-clean)", dirty: "var(--proj-dirty)", ahead: "var(--proj-ahead)", behind: "var(--proj-behind)", diverged: "var(--proj-diverged)", conflict: "var(--proj-conflict)", missing: "var(--proj-missing)", syncing: "var(--proj-syncing)", stale: "var(--proj-stale)" };
const ZK_BM_STATE = { synced: "in sync with origin", ahead: "ahead of origin", behind: "behind origin", local: "local only", remote: "remote only", diverged: "diverged from origin" };
const zkBmShort = (b) => b.state === "ahead" ? "↑" + (b.ahead || 1) : b.state === "synced" ? "✓" : b.state === "diverged" ? "↕" : b.state === "behind" ? "↓" : b.state;

// motion tokens in ms (tokens/motion.css) — the kit reads them so its timers never drift from the system
const zkMs = (name, fallback) => { const n = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name)); return isNaN(n) ? fallback : n; };

function zkUseOutside(open, close, ignore) {
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (!open) return;
    const h = (e) => { if (ref.current && !ref.current.contains(e.target) && !(ignore && e.target.closest(ignore))) close(); };
    const k = (e) => { if (e.key === "Escape") { e.stopPropagation(); close(); } };
    window.addEventListener("pointerdown", h, true); window.addEventListener("keydown", k, true);
    return () => { window.removeEventListener("pointerdown", h, true); window.removeEventListener("keydown", k, true); };
  }, [open]);
  return ref;
}

// the gap legend: what dashed edges mean
function ZKGaps({ n, onShowAll }) {
  if (!n) return null;
  const glyph = (gap) => <svg width="22" height="22" viewBox="0 0 28 28" aria-hidden="true">{gap === "end"
    ? <g className="zs-gap"><path className="zs-edge is-gap" d="M14,4 L14,12"/><line className="zs-gap-cut" x1="9" y1="16.7" x2="19" y2="12.3"/><line className="zs-gap-cut" x1="9" y1="21.2" x2="19" y2="16.8"/></g>
    : <GraphEdge from={[14, 27]} to={[14, 1]} gap={gap}/>}</svg>;
  return (
    <div className="zk-gaps">
      <button type="button" className="zk-gaps-btn" aria-label="What dashed edges mean">
        <svg width="12" height="18" viewBox="7 2 14 24" aria-hidden="true"><GraphEdge from={[14, 26]} to={[14, 2]} gap/></svg>
        <span>{n} {n === 1 ? "gap" : "gaps"}</span>
      </button>
      <div className="zk-gaps-pop">
        <div className="zk-gaps-inner">
          <div className="zk-gaps-title">This revset hides part of the history</div>
          <div className="zk-gaps-row">{glyph(false)}<span><b>Solid</b> — direct parent</span></div>
          <div className="zk-gaps-row">{glyph(true)}<span><b>Dashed</b> — commits in between are hidden</span></div>
          <div className="zk-gaps-row">{glyph("end")}<span><b>End</b> — older history isn’t in the revset</span></div>
          <div className="zk-gaps-desc">Stacks never span a gap. Hover a marker for details.</div>
          <div><button type="button" className="zk-gaps-all" onClick={onShowAll}>Show <code>all()</code></button></div>
        </div>
      </div>
    </div>
  );
}

function ZKTopBar({ D, project, recent, activeId, onPickProject, onAllProjects, onSettings, revset, setRevset, home, configs, changes, visible, onGoTo, onEditConfigs, shown, total, gaps, opts, setOpt, onNew, onPush }) {
  const [vw, setVw] = React.useState(false), [pm, setPm] = React.useState(false);
  const vwRef = zkUseOutside(vw, () => setVw(false)), pmRef = zkUseOutside(pm, () => setPm(false));
  const [ww, setWw] = React.useState(window.innerWidth);
  React.useEffect(() => { const f = () => setWw(window.innerWidth); window.addEventListener("resize", f); return () => window.removeEventListener("resize", f); }, []);
  const filtered = shown < total;
  return (
    <>
    {/* the system's buttons (a mock); the bar starts at block end + 12 and centres on them */}
    <TrafficLights className="zk-lights"/>
    <div className="zk-top">
      <div className="zk-tl">
        <div className="zk-anchor" ref={pmRef}>
          <Island shape="bar" as="button" className={"zk-proj" + (pm ? " is-on" : "")} onClick={() => setPm(!pm)} aria-haspopup="menu" aria-expanded={pm} title={project.path}>
            <NamiMark size={28} chip/>
            <span className="zk-proj-name">{project.name}</span>
            <span className="zk-dot" style={{ background: ZK_STATUS[project.status] }}></span>
            <Icon name="chevron-down" size="md"/>
          </Island>
          {pm && <ProjectMenu className="zk-pop-pm" autoFocus onClose={() => setPm(false)} recent={recent} activeId={activeId} onPick={(p) => { setPm(false); onPickProject(p.id); }}
            onAll={() => { setPm(false); onAllProjects(); }} onProjectSettings={() => { setPm(false); onSettings("project"); }} onSettings={() => { setPm(false); onSettings(); }}/>}
        </div>
      </div>
      <Island shape="bar" className="zk-tc">
        <window.ZKSearch D={D} revset={revset} setRevset={setRevset} home={home} configs={configs} changes={changes} visible={visible} size={GraphSearch.sizeFor(ww)} onGoTo={onGoTo} onEdit={onEditConfigs}/>
        <ZKGaps n={gaps} onShowAll={() => setRevset("all")}/>
        <span className="zk-n" title={shown + " of " + total + " changes shown"}>{filtered ? <><b>{shown}</b> of {total}</> : <><b>{total}</b> changes</>}</span>
        <IslandSeparator/>
        <div className="zk-anchor" ref={vwRef}>
          <IconButton icon="view-options" label="View options" active={vw} onClick={() => setVw(!vw)} aria-expanded={vw}/>
          {vw && (
            <Popover className="zk-pop-r" aria-label="View options">
              <PopoverHeader>Graph view</PopoverHeader>
              <OptionRow label="Layout"><Segmented label="Layout" value={opts.layout} onChange={(v) => setOpt("layout", v)} options={[{ value: "free", label: "Free", title: "Rows follow commit time" }, { value: "compact", label: "Compact", title: "Rows = dependency depth" }]}/></OptionRow>
              <OptionRow label="Detailed cards"><Switch label="Detailed cards" checked={opts.detailed} onChange={(v) => setOpt("detailed", v)}/></OptionRow>
              <OptionRow label="Group stacks" title="Collapse linear runs of changes into one stack card"><Switch label="Group stacks" checked={opts.stacks} onChange={(v) => setOpt("stacks", v)}/></OptionRow>
              <OptionRow label="Card width"><Slider label="Card width" min={160} max={400} step={10} value={opts.cardW} unit="px" width={120} onChange={(v) => setOpt("cardW", v)}/></OptionRow>
              <PopoverSeparator/>
              <OptionLink label="Appearance, diffs and more" action="Settings…" onClick={() => { setVw(false); onSettings("general"); }}/>
            </Popover>
          )}
        </div>
      </Island>
      <div className="zk-tr">
        <Island shape="bar">
          <IconButton icon="fetch" label="Fetch" badge={3} title="Fetch — jj git fetch · 3 new changes on origin"/>
          <IconButton icon="push" label="Push…" title="Push… — choose what jj git push sends" onClick={onPush}/>
        </Island>
        <Button variant="primary" size="lg" icon="plus" iconSize="lg" title="jj new — start a new change on top of @" onClick={onNew}>New change</Button>
      </div>
    </div>
    </>
  );
}

function ZKBookmarkList({ changes, visible, onPick, limit }) {
  const rows = changes.flatMap((c) => c.bookmarks.map((b) => ({ b, c }))).slice(0, limit || undefined);
  return (
    <div className="zk-bl">
      {rows.map(({ b, c }) => (
        <button key={b.name} type="button" className={"zk-bl-row" + (visible.has(c.id) ? "" : " is-hidden")} onClick={() => onPick(c.id)} title={b.name + " — " + ZK_BM_STATE[b.state]}>
          <Icon name="bookmark-filled" size="sm"/>
          <span className="zk-bl-text"><span className="zk-bl-name">{b.name}</span><span className="zk-bl-sub"><b>{c.id.slice(0, 2)}</b>{c.id.slice(2, 8)} · {c.subject || "(no description set)"}</span></span>
          <span className={"zs-bm-state s-" + b.state}>{zkBmShort(b)}</span>
        </button>
      ))}
    </div>
  );
}

function ZKRailContent({ id, changes, visible, ops, onPick, preview }) {
  if (id === "bookmarks") {
    const n = changes.reduce((s, c) => s + c.bookmarks.length, 0);
    return <>{<ZKBookmarkList changes={changes} visible={visible} onPick={onPick} limit={preview ? 5 : 0}/>}{preview && n > 5 && <div className="zk-co-more">+{n - 5} more</div>}</>;
  }
  if (id === "reviews") return <CalloutText>No open reviews.</CalloutText>;
  return <div className="zk-ops">{ops.slice(0, preview ? 3 : 12).map((o, i) => <div key={i} className="zk-op"><code>{o.cmd}</code><span>{o.when}</span></div>)}</div>;
}

function ZKRail({ pinned, setPinned, changes, visible, ops, opCount, onPick }) {
  const [co, setCo] = React.useState(null);
  const openT = React.useRef(0), closeT = React.useRef(0);
  const clear = () => { clearTimeout(openT.current); clearTimeout(closeT.current); };
  const enter = (it, e) => {
    clear(); if (pinned === it.id) { setCo(null); return; }
    const r = e.currentTarget.getBoundingClientRect(), next = { it, top: r.top + r.height / 2 };
    if (co) setCo(next); else openT.current = setTimeout(() => setCo(next), zkMs("--delay-callout", 90));
  };
  const leave = () => { clear(); closeT.current = setTimeout(() => setCo(null), zkMs("--delay-callout-out", 200)); };
  const count = (id) => id === "bookmarks" ? changes.reduce((s, c) => s + c.bookmarks.length, 0) : id === "undo" ? opCount + " ops" : null;
  const pin = ZK_RAIL.find((r) => r.id === pinned);
  return (
    <>
      <Island shape="rail" as="nav" className="zk-rail" aria-label="Panels">
        {ZK_RAIL.map((it) => (
          <IconButton key={it.id} size="lg" icon={it.icon} iconSize="rail" label={it.label} title="" active={pinned === it.id} className={co && co.it.id === it.id ? "is-hov" : ""}
            onClick={() => { clear(); setCo(null); setPinned(pinned === it.id ? null : it.id); }} onMouseEnter={(e) => enter(it, e)} onMouseLeave={leave} aria-pressed={pinned === it.id}/>
        ))}
      </Island>
      {co && pinned !== co.it.id && (
        <div className="zk-callout" style={{ top: co.top }} onMouseEnter={clear} onMouseLeave={leave}>
          <Callout icon={co.it.icon} title={co.it.label} count={count(co.it.id)}>
            <ZKRailContent id={co.it.id} changes={changes} visible={visible} ops={ops} preview onPick={(id) => { setCo(null); onPick(id); }}/>
          </Callout>
        </div>
      )}
      {pin && (
        <Island shape="panel" className="zk-panel" key={pin.id} aria-label={pin.label}>
          <div className="zk-panel-hd"><Icon name={pin.icon} size="lg"/><span>{pin.label}</span><IconButton icon="close" iconSize="sm" size="sm" label="Close" onClick={() => setPinned(null)}/></div>
          <div className="zk-panel-bd"><ZKRailContent id={pin.id} changes={changes} visible={visible} ops={ops} onPick={onPick}/></div>
        </Island>
      )}
    </>
  );
}

Object.assign(window, { ZKTopBar, ZKRail, ZK_STATUS, ZK_BM_STATE, zkBmShort, zkUseOutside, zkMs });
})();
