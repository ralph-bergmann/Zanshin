/* global React */
// DIRECT MANIPULATION — what can happen when something is dropped on a change, the menu that offers it, the ghost under the pointer.
// The drop menu opens over the target after a short rest; the most likely action sits nearest the card and is what a plain drop does.
(() => {
const O = () => window.GraphOps;
const ID = ({ id }) => <span className="gcid"><b>{id.slice(0, 2)}</b>{id.slice(2, 8)}</span>;
const short8 = (id) => id.slice(0, 8);
const fname = (p) => p.split("/").pop();

const G = { stroke: "currentColor", strokeWidth: 1.4, fill: "none", strokeLinecap: "round", strokeLinejoin: "round" };
const DROP_ICON = {
  onto: <g {...G}><path d="M8 2v8.5M4.5 7l3.5 3.5L11.5 7"/><path d="M3 14h10"/></g>,
  only: <g {...G}><rect x="5" y="1.5" width="6" height="4.5" rx="1.2"/><path d="M8 7.5v3.5M6 9.5l2 2 2-2"/><path d="M3 14h10"/></g>,
  after: <g {...G}><path d="M3.5 1.75h9"/><path d="M8 4v4.5M5.75 6.25h4.5"/><rect x="2.5" y="10.5" width="11" height="3.75" rx="1.2"/></g>,
  before: <g {...G}><rect x="2.5" y="1.75" width="11" height="3.75" rx="1.2"/><path d="M8 7.5v4.5M5.75 9.75h4.5"/><path d="M3.5 14.25h9"/></g>,
  squash: <g {...G}><rect x="2.5" y="9" width="11" height="5" rx="1.3"/><path d="M8 1.5v5.5M5.5 4.5L8 7l2.5-2.5"/></g>,
  merge: <g {...G}><circle cx="8" cy="3" r="1.6"/><path d="M8 4.6V7c0 2-4 2-4 4.5V14M8 7c0 2 4 2 4 4.5V14"/></g>,
  dup: <g {...G}><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M3 10.5V3.5a1 1 0 0 1 1-1h7"/></g>,
  bookmark: <path d="M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z" {...G}/>,
};

// ------------------------------------------------------------
// ACTIONS — only what makes sense for this source and this target, most likely first
// ------------------------------------------------------------
function dropActionsFor(p, tid, ctx) {
  const { all } = ctx, M = new Map(all.map(c => [c.id, c])), T = M.get(tid), ops = O();
  if (!T) return [];
  const b = short8(tid);
  if (p.kind === "change") {
    const A = M.get(p.id);
    if (!A || A.id === tid) return [];
    const a = short8(A.id), desc = ops.descendants(all, A.id), anc = ops.ancestors(all, A.id);
    const isDesc = desc.has(tid), isAnc = anc.has(tid);
    const onParent = A.parents.length === 1 && A.parents[0] === tid, onChild = T.parents.length === 1 && T.parents[0] === A.id;
    const mutA = !A.immutable && !A.isRoot, mutT = !T.immutable && !T.isRoot;
    const kidsMut = all.every(c => !c.parents.includes(tid) || c.id === A.id || !c.immutable);
    const out = [];
    const moved = (verb, how) => ({ text: [verb + " ", { id: A.id }, how, { id: tid }] });
    if (mutA && !isDesc && !onParent) out.push({ id: "onto", group: "move", icon: "onto", label: desc.size ? "Move here" : "Move here", short: "rebase -s", cmd: `jj rebase -s ${a} -o ${b}`,
      apply: (all) => ({ all: ops.rebase(all, A.id, tid, "s"), anchor: tid, flash: [A.id], toast: moved("Moved", " onto ") }) });
    if (mutA && desc.size && !isDesc && !onParent) out.push({ id: "only", group: "move", icon: "only", label: "Move only this change", short: "rebase -r", cmd: `jj rebase -r ${a} -o ${b}`,
      apply: (all) => ({ all: ops.rebase(all, A.id, tid, "r"), anchor: tid, flash: [A.id], toast: moved("Moved", " onto ") }) });
    if (mutA && !T.isRoot && kidsMut && !onParent) out.push({ id: "after", group: "place", icon: "after", label: "Insert after", short: "rebase -A", cmd: `jj rebase -r ${a} -A ${b}`,
      apply: (all) => ({ all: ops.insertAfter(all, A.id, tid), anchor: tid, flash: [A.id], toast: moved("Inserted", " after ") }) });
    if (mutA && mutT && !onChild) out.push({ id: "before", group: "place", icon: "before", label: "Insert before", short: "rebase -B", cmd: `jj rebase -r ${a} -B ${b}`,
      apply: (all) => ({ all: ops.insertBefore(all, A.id, tid), anchor: tid, flash: [A.id], toast: moved("Inserted", " before ") }) });
    if (mutA && mutT) out.push({ id: "squash", group: "combine", icon: "squash", label: "Squash into this change", short: "squash", cmd: `jj squash --from ${a} --into ${b}`,
      apply: (all, diffs) => { const r = ops.squash(all, diffs, A.id, tid, null); return { ...r, anchor: tid, flash: [tid], select: ctx.selectedId === A.id && r.gone ? tid : undefined, toast: moved("Squashed", " into ") }; } });
    if (!isDesc && !isAnc && !T.isRoot) out.push({ id: "merge", group: "combine", icon: "merge", label: "New merge change", short: "new", cmd: `jj new ${b} ${a}`,
      apply: (all, diffs, mk) => { const nid = mk(); const r = ops.mergeNew(all, diffs, tid, A.id, nid); return { ...r, wc: nid, born: nid, anchor: tid, toast: { text: ["Merged ", { id: A.id }, " and ", { id: tid }, " in a new change"] } }; } });
    if (!T.isRoot && !A.isRoot) out.push({ id: "dup", group: "copy", icon: "dup", label: "Duplicate here", short: "duplicate", cmd: `jj duplicate ${a} -o ${b}`,
      apply: (all, diffs, mk) => { const nid = mk(); const r = ops.duplicate(all, diffs, A.id, tid, nid); return { ...r, born: nid, anchor: tid, toast: { text: ["Duplicated ", { id: A.id }, " onto ", { id: tid }] } }; } });
    return out;
  }
  if (p.kind === "bookmark") {
    if (tid === p.from || T.isRoot) return [];
    const fwd = ops.descendants(all, p.from).has(tid);
    const nm = window.shortBookmark ? window.shortBookmark(p.name) : { main: p.name };
    return [{ id: "bm", group: "move", icon: "bookmark", label: `Move ${nm.main} here`, short: fwd ? "bookmark move" : "backwards", note: fwd ? null : "backwards",
      cmd: `jj bookmark move ${p.name} --to ${b}${fwd ? "" : " --allow-backwards"}`,
      apply: (all) => ({ all: ops.moveBookmark(all, p.name, p.from, tid), flash: [tid], toast: { text: ["Moved ", { mono: nm.main }, " to ", { id: tid }] } }) }];
  }
  if (p.kind === "diff") {
    if (tid === p.from || T.immutable || T.isRoot) return [];
    const a = short8(p.from), files = p.files || [], whole = p.whole;
    const paths = whole ? " " + files.map(f => f.path).join(" ") : " -i";
    const what = p.label;
    const out = [
      { id: "into", group: "move", icon: "squash", label: "Move into this change", short: "squash", cmd: `jj squash --from ${a} --into ${b}${paths}`,
        apply: (all, diffs) => ({ ...ops.squash(all, diffs, p.from, tid, p.hunkIds), flash: [tid], toast: { text: ["Moved " + what + " into ", { id: tid }] } }) },
    ];
    const kidsMut = all.every(c => !c.parents.includes(tid) || !c.immutable);
    if (kidsMut) out.push({ id: "after", group: "place", icon: "after", label: "Into a new change after", short: "split -A", cmd: `jj split -r ${a} -A ${b}${paths}`,
      apply: (all, diffs, mk) => { const nid = mk(); return { ...ops.splitTo(all, diffs, p.from, p.hunkIds, "A", tid, nid, ""), born: nid, anchor: tid, toast: { text: ["Moved " + what + " into a new change after ", { id: tid }] } }; } });
    out.push({ id: "before", group: "place", icon: "before", label: "Into a new change before", short: "split -B", cmd: `jj split -r ${a} -B ${b}${paths}`,
      apply: (all, diffs, mk) => { const nid = mk(); return { ...ops.splitTo(all, diffs, p.from, p.hunkIds, "B", tid, nid, ""), born: nid, anchor: tid, toast: { text: ["Moved " + what + " into a new change before ", { id: tid }] } }; } });
    return out;
  }
  return [];
}

// ------------------------------------------------------------
// DROP MENU — rendered inside the graph plane so it scrolls with its card.
// place "above": items run bottom-up from the card (priority order, like iOS menus that open away from the finger)
// ------------------------------------------------------------
function DropMenu({ menu, actions, over }) {
  const order = actions.map((a, i) => ({ a, i }));
  const rows = menu.place === "above" ? order.slice().reverse() : order;
  const cur = actions[menu.sel] || actions[0];
  const cmd = <div className="gdrop-cmd" title={cur.cmd}><code>{cur.cmd}</code></div>;
  return (
    <div className={"gdrop is-" + menu.place + (over ? " is-over" : "") + (actions.length === 1 ? " is-single" : "")} style={{ left: menu.x, top: menu.y }} role="menu" aria-label="Drop actions">
      {menu.place === "below" && cmd}
      <div className="gdrop-list">
        {rows.map(({ a, i }, k) => (
          <React.Fragment key={a.id}>
            {k > 0 && rows[k - 1].a.group !== a.group && <div className="gdrop-sep"></div>}
            <div className={"gdrop-item" + (i === menu.sel ? " on" : "")} data-act={i} role="menuitem">
              <svg width="15" height="15" viewBox="0 0 16 16">{DROP_ICON[a.icon]}</svg>
              <span className="gdrop-l">{a.label}</span>
              {a.note ? <span className="gdrop-note">{a.note}</span> : <span className="gdrop-k">{a.short}</span>}
            </div>
          </React.Fragment>
        ))}
      </div>
      {menu.place === "above" && cmd}
    </div>
  );
}

// ------------------------------------------------------------
// GHOST — what is in your hand
// ------------------------------------------------------------
function DragGhost({ drag, commit, isWC }) {
  const p = drag.payload, acts = drag.actions, def = acts && acts[drag.sel];
  let chip;
  if (p.kind === "change" && commit) chip = <div className="gghost-card">{isWC && <span className="gat sm">@</span>}<ID id={commit.id}/><span className="gghost-subj">{commit.subject}</span></div>;
  else if (p.kind === "bookmark") { const s = window.shortBookmark ? window.shortBookmark(p.name) : { main: p.name }; chip = <div className="gghost-card is-bm"><svg width="12" height="12" viewBox="0 0 16 16">{DROP_ICON.bookmark}</svg><span className="gghost-bm">{s.main}</span>{s.rest && <span className="gghost-rest">{s.rest}</span>}</div>; }
  else if (p.kind === "diff") chip = (
    <div className="gghost-card is-diff">
      {p.files.length === 1 ? <><span className={"file-status status-" + p.files[0].status}>{p.files[0].status}</span><span className="gghost-subj mono">{p.hunk ? p.hunk : fname(p.files[0].path)}</span></>
        : <span className="gghost-subj">{p.label}</span>}
      <span className="gghost-stat"><span className="stat-add">+{p.a}</span><span className="stat-rem">−{p.r}</span></span>
    </div>
  );
  const hint = p.kind === "change" ? "Drop on a change" : p.kind === "bookmark" ? "Drop on the change it should point to" : "Drop on the change it belongs to";
  return (
    <div className={"gghost" + (drag.overMenu ? " is-muted" : "")} style={{ left: drag.x, top: drag.y }} aria-hidden="true">
      {chip}
      {!drag.menu && <div className={"gghost-cmd" + (def ? " on" : "")}>{def ? <span>{def.cmd}</span> : <span className="gghost-alt">{hint}</span>}</div>}
    </div>
  );
}

// ------------------------------------------------------------
// TOAST — every graph edit can be taken back (jj undo)
// ------------------------------------------------------------
function OpToast({ toast, onUndo, onClose, style }) {
  return (
    <div className="gtoast" style={style} role="status" key={toast.n}>
      <span className="gtoast-t">{toast.text.map((s, i) => typeof s === "string" ? <React.Fragment key={i}>{s}</React.Fragment> : s.id ? <ID key={i} id={s.id}/> : <code key={i}>{s.mono}</code>)}</span>
      <button className="gtoast-undo" onClick={onUndo} title="jj undo">Undo</button>
      <button className="gtoast-x" onClick={onClose} aria-label="Dismiss"><svg width="10" height="10" viewBox="0 0 16 16"><path d="M3.5 3.5l9 9M12.5 3.5l-9 9" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></svg></button>
    </div>
  );
}

Object.assign(window, { dropActionsFor, DropMenu, DragGhost, OpToast, DROP_ICON });
})();
