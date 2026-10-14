/* global React */
// INSPECTOR (floating) — reading and shaping one change.
// Reading: title, meta, files, hunks. Shaping: the title is the describe field; checkboxes pick hunks; the composer
// turns a selection into a commit (@: jj commit) or a split (jj split -r). Every file and hunk can be dragged onto another change.
(() => {
const { useState, useEffect, useMemo, useRef } = React;
const Ic = (p) => <window.Icon {...p}/>;
const fname = (p) => p.split("/").pop();
const first = (s) => (s || "").split("\n")[0].trim();
const sum = (hunks) => hunks.reduce((s, h) => { h.lines.forEach(l => { if (l.k === "+") s.a++; else if (l.k === "-") s.r++; }); return s; }, { a: 0, r: 0 });
const STATE_LABEL = { synced: "in sync with origin", ahead: "ahead of origin", behind: "behind origin", local: "local only", remote: "remote only", diverged: "diverged from origin" };
const PEN = <svg className="gins-pen" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 13l.6-2.6L10.5 3.5l2 2-6.9 6.9L3 13zM9.3 4.7l2 2" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round"/></svg>;
const GRIP = <svg className="ghunk-grip" width="10" height="12" viewBox="0 0 10 12" aria-hidden="true"><g fill="currentColor"><circle cx="3" cy="2.5" r="1"/><circle cx="7" cy="2.5" r="1"/><circle cx="3" cy="6" r="1"/><circle cx="7" cy="6" r="1"/><circle cx="3" cy="9.5" r="1"/><circle cx="7" cy="9.5" r="1"/></g></svg>;

function Check({ state, onToggle, label }) {
  return (
    <button className={"gck" + (state === "all" ? " on" : state === "some" ? " mixed" : "")} role="checkbox" aria-checked={state === "all" ? true : state === "some" ? "mixed" : false}
      aria-label={label} title={label} onPointerDown={e => e.stopPropagation()} onClick={e => { e.stopPropagation(); onToggle(); }}>
      {state === "all" && <svg width="10" height="10" viewBox="0 0 16 16"><path d="M3 8.5l3 3 7-7" stroke="currentColor" strokeWidth="2.2" fill="none" strokeLinecap="round" strokeLinejoin="round"/></svg>}
      {state === "some" && <svg width="10" height="10" viewBox="0 0 16 16"><path d="M4 8h8" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/></svg>}
    </button>
  );
}

// ------------------------------------------------------------
// DESCRIPTION — one way to write it, wherever it is written: a summary line, then details
// ------------------------------------------------------------
const joinMsg = (s, b) => (s.trim() + (b.trim() ? "\n\n" + b.trim() : "")).trim();
function DescFields({ s, setS, b, setB, placeholder, onSubmit, onCancel, inputRef }) {
  const key = (e) => {
    if (e.key === "Escape" && onCancel) { e.preventDefault(); onCancel(); }
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey || e.target.tagName === "INPUT")) { e.preventDefault(); onSubmit(); }
  };
  return (
    <div className="gdesc-fields" onKeyDown={key}>
      <input ref={inputRef} className="gdesc-subj" value={s} onChange={e => setS(e.target.value)} placeholder={placeholder || "Summary"} aria-label="Summary"/>
      <textarea className="gdesc-body" value={b} onChange={e => setB(e.target.value)} placeholder="Details (optional)" rows={2} aria-label="Details"/>
    </div>
  );
}

// the title is the field
function DescribeForm({ commit, onSave, onCancel }) {
  const undescribed = !commit.description && /^\(no description/.test(commit.subject);
  const [s, setS] = useState(undescribed ? "" : commit.subject);
  const [b, setB] = useState(commit.description || "");
  const ref = useRef(null);
  useEffect(() => { const t = setTimeout(() => { if (ref.current) { ref.current.focus(); ref.current.select(); } }, 20); return () => clearTimeout(t); }, []);
  const save = () => onSave(s, b);
  return (
    <div className="gdesc">
      <DescFields s={s} setS={setS} b={b} setB={setB} onSubmit={save} onCancel={onCancel} inputRef={ref}/>
      <div className="gdesc-ft">
        <code title={`jj describe -r ${commit.id}`}>jj describe -r {commit.id.slice(0, 8)} -m “{first(s) || "…"}”</code>
        <button className="gins-btn" onClick={onCancel}>Cancel</button>
        <button className="gins-btn primary" onClick={save}>Save</button>
      </div>
    </div>
  );
}

// ------------------------------------------------------------
// HUNK
// ------------------------------------------------------------
function HunkBody({ h, mode }) {
  if (mode !== "split") return (
    <div className="diff-body">
      {h.lines.map((l, i) => (
        <div key={i} className={"diff-line " + (l.k === "+" ? "add" : l.k === "-" ? "remove" : "context")}>
          <span className="sigil">{l.k === "+" ? "+" : l.k === "-" ? "−" : " "}</span><span className="txt">{l.s}</span>
        </div>
      ))}
    </div>
  );
  const rows = []; let i = 0;
  const ls = h.lines;
  while (i < ls.length) {
    if (ls[i].k === " ") { rows.push([ls[i], ls[i]]); i++; continue; }
    const rem = [], add = [];
    while (i < ls.length && ls[i].k === "-") rem.push(ls[i++]);
    while (i < ls.length && ls[i].k === "+") add.push(ls[i++]);
    for (let k = 0; k < Math.max(rem.length, add.length); k++) rows.push([rem[k] || null, add[k] || null]);
  }
  return (
    <div className="diff-body split">
      {rows.map(([a, b], k) => (
        <div key={k} className="diff-row">
          <div className={"side " + (a ? (a.k === "-" ? "remove" : "context") : "empty")}><span className="txt">{a ? a.s : ""}</span></div>
          <div className={"side " + (b ? (b.k === "+" ? "add" : "context") : "empty")}><span className="txt">{b ? b.s : ""}</span></div>
        </div>
      ))}
    </div>
  );
}

function Hunk({ f, h, mode, mutable, selected, lifted, onToggle, onDragStart }) {
  const st = sum([h]);
  const oc = h.lines.filter(l => l.k !== "+").length, nc = h.lines.filter(l => l.k !== "-").length;
  return (
    <div className={"ghunk" + (selected ? " is-sel" : "") + (lifted ? " is-lifted" : "")}>
      <div className={"ghunk-hd" + (mutable ? " is-grab" : "")} onPointerDown={mutable ? (e) => onDragStart(e, f, h) : undefined}
        title={mutable ? "Drag onto a change to move this hunk there" : undefined}>
        {mutable && <Check state={selected ? "all" : "none"} onToggle={onToggle} label={selected ? "Deselect hunk" : "Select hunk"}/>}
        <code className="ghunk-range">@@ −{h.oldStart},{oc} +{h.newStart},{nc} @@</code>
        {h.ctx && <span className="ghunk-ctx">{h.ctx}</span>}
        <span className="ghunk-stat">{st.a > 0 && <span className="stat-add">+{st.a}</span>}{st.r > 0 && <span className="stat-rem">−{st.r}</span>}</span>
        {mutable && GRIP}
      </div>
      <HunkBody h={h} mode={mode}/>
    </div>
  );
}

// ------------------------------------------------------------
// COMPOSER — what the selection becomes. The two rows are the result, drawn the way the graph draws it (child above).
// ------------------------------------------------------------
function Composer({ commit, isWC, files, sel, subj, setSubj, body, setBody, onRun, onClear, valid }) {
  const id8 = commit.id.slice(0, 8);
  const msg = joinMsg(subj, body);
  const selFiles = files.map(f => ({ f, hs: f.hunks.filter(h => sel.has(h.id)) })).filter(x => x.hs.length);
  const restFiles = files.map(f => ({ f, hs: f.hunks.filter(h => !sel.has(h.id)) })).filter(x => x.hs.length);
  const s = sum(selFiles.flatMap(x => x.hs)), r = sum(restFiles.flatMap(x => x.hs));
  const partial = selFiles.some(x => x.hs.length < x.f.hunks.length);
  const everything = !restFiles.length;
  const m = msg ? ` -m "${first(msg)}${msg.includes("\n") ? "…" : ""}"` : "";
  const paths = partial ? " -i" : isWC && everything ? "" : " " + selFiles.map(x => x.f.path).join(" ");
  const cmd = isWC ? `jj commit${m}${paths}` : `jj split -r ${id8}${m}${paths}`;
  const nf = (n) => n + (n === 1 ? " file" : " files");
  const stat = (x) => <span className="gcomp-stat">{x.a > 0 && <span className="stat-add">+{x.a}</span>}{x.r > 0 && <span className="stat-rem">−{x.r}</span>}</span>;
  const go = () => { if (valid) onRun(); };
  return (
    <div className="gcomp" role="group" aria-label={isWC ? "Commit" : "Split"}>
      <DescFields s={subj} setS={setSubj} b={body} setB={setBody} onSubmit={go}
        placeholder={isWC ? "Summary of what you did" : "Summary of the selected changes"}/>
      <div className="gcomp-result" aria-label="Result">
        <div className={"gcomp-node is-rest" + (isWC ? " is-wc" : "")}>
          <span className="gcomp-dot"></span>
          {isWC ? <><span className="gat sm">@</span><span className="gcomp-l">New working copy</span></> : <span className="gcomp-l">Rest</span>}
          <span className="gcomp-m">{everything ? "empty" : <>{nf(restFiles.length)} {stat(r)}</>}</span>
          <span className="gcomp-n">{isWC ? "stays here to keep working" : <>keeps “{first(commit.subject)}”</>}</span>
        </div>
        <div className="gcomp-node is-sel">
          <span className="gcomp-dot"></span>
          <span className="gcomp-l">Selected</span>
          <span className="gcomp-m">{sel.size ? <>{nf(selFiles.length)} {stat(s)}</> : "nothing yet"}</span>
          <span className={"gcomp-n" + (msg ? " is-msg" : "")}>{msg ? <>“{first(msg)}”</> : "no description yet"}</span>
        </div>
      </div>
      <div className="gcomp-ft">
        <code className="gcomp-cmd" title={cmd}>{cmd}</code>
        {!isWC && <button className="gins-btn" onClick={onClear}>Cancel</button>}
        <button className="gins-btn primary" disabled={!valid} onClick={go} title="⌘↩">{isWC ? "Commit" : "Split"}</button>
      </div>
      {!isWC && everything && <div className="gcomp-hint">Everything is selected — leave something behind to split it in two.</div>}
    </div>
  );
}

// ------------------------------------------------------------
// INSPECTOR
// ------------------------------------------------------------
function GraphInspector({ commit, isWC, files, editing, setEditing, canSquash, onClose, onEdit, onNew, onDescribe, onSplit, onCommit, onSquash, onAbandon, beginDrag, lift, t, setTweak }) {
  const mutable = !commit.immutable && !commit.isRoot;
  const undescribed = !commit.description && /^\(no description/.test(commit.subject);
  const allIds = useMemo(() => files.flatMap(f => f.hunks.map(h => h.id)), [files]);
  const [selRaw, setSel] = useState(() => new Set(isWC ? allIds : []));
  const sel = useMemo(() => new Set([...selRaw].filter(id => allIds.includes(id))), [selRaw, allIds]);
  const [focus, setFocus] = useState(files[0] && files[0].path);
  const ff = files.find(f => f.path === focus) || files[0];
  const [subj, setSubj] = useState(""), [body, setBody] = useState("");
  const [reviewed, setViewed, setMany] = window.useReviewState(commit.id);
  const viewedN = files.filter(f => reviewed[f.path]).length;
  const tot = sum(files.flatMap(f => f.hunks));
  const parents = (commit.parents || []).map(p => typeof p === "string" ? p : p.id);
  const when = commit.date === "now" ? "just now" : commit.date;
  const liftSet = lift ? new Set(lift) : null;
  const composing = mutable && (isWC ? files.length > 0 : sel.size > 0);
  const everything = sel.size === allIds.length;
  const valid = sel.size > 0 && (isWC || !everything);

  // Esc clears a split selection before it closes the panel
  useEffect(() => {
    if (isWC || !sel.size || editing) return;
    const k = (e) => { if (e.key === "Escape" && !e.defaultPrevented) { e.stopImmediatePropagation(); setSel(new Set()); } };
    window.addEventListener("keydown", k, true);
    return () => window.removeEventListener("keydown", k, true);
  }, [isWC, sel.size, editing]);

  const toggle = (ids) => setSel(s => { const n = new Set([...s].filter(id => allIds.includes(id))); const on = ids.every(id => n.has(id)); ids.forEach(id => on ? n.delete(id) : n.add(id)); return n; });
  const fileState = (f) => { const k = f.hunks.filter(h => sel.has(h.id)).length; return k === 0 ? "none" : k === f.hunks.length ? "all" : "some"; };
  const allState = sel.size === 0 ? "none" : everything ? "all" : "some";

  const payload = (ids, h) => {
    const set = new Set(ids);
    const fs = files.map(f => ({ f, hs: f.hunks.filter(x => set.has(x.id)) })).filter(x => x.hs.length);
    const s = sum(fs.flatMap(x => x.hs)), whole = fs.every(x => x.hs.length === x.f.hunks.length);
    const label = fs.length === 1 ? (whole ? fname(fs[0].f.path) : (ids.length === 1 ? "a hunk of " : ids.length + " hunks of ") + fname(fs[0].f.path))
      : whole ? fs.length + " files" : ids.length + " hunks from " + fs.length + " files";
    return { kind: "diff", from: commit.id, hunkIds: ids, files: fs.map(x => ({ path: x.f.path, status: x.f.status })), whole, a: s.a, r: s.r, label,
      hunk: h && ids.length === 1 ? (h.ctx || fname(fs[0].f.path)) : null };
  };
  const dragFile = (e, f) => {
    const ids = f.hunks.map(h => h.id);
    beginDrag(e, payload(sel.size > 1 && ids.some(id => sel.has(id)) ? [...sel] : ids));
  };
  const dragHunk = (e, f, h) => beginDrag(e, payload(sel.size > 1 && sel.has(h.id) ? [...sel] : [h.id], h));

  const run = () => {
    const ids = [...sel];
    const msg = joinMsg(subj, body);
    if (isWC) onCommit(ids, msg); else onSplit(ids, msg);
    setSubj(""); setBody(""); setSel(new Set());
  };

  const actions = !mutable
    ? [<button key="new" className="gins-btn primary" onClick={() => onNew(commit.id)} title={`jj new ${commit.id.slice(0, 8)}`}><Ic name="plus" size={13}/><span>New change on top</span></button>]
    : [
      isWC ? <button key="new" className="gins-btn" onClick={() => onNew(commit.id)} title="jj new — leave this change as it is and start a new one">New change</button>
        : <button key="edit" className={"gins-btn" + (composing ? "" : " primary")} onClick={onEdit} title="Move the working copy here — jj edit"><span className="gat sm">@</span><span>Edit</span></button>,
      <button key="sq" className="gins-btn" disabled={!canSquash} onClick={onSquash} title={canSquash ? "jj squash — fold into the parent" : "The parent can’t be rewritten"}>Squash into parent</button>,
      <button key="ab" className="gins-btn danger" onClick={onAbandon} title="jj abandon">Abandon</button>,
    ];

  return (
    <section className={"gdetail gins" + (composing ? " is-composing" : "")} style={{ "--branch-color": "var(--accent)" }} data-screen-label={`Detail ${commit.id}`}>
      <header className="gins-hd">
        <span className="gins-id" title={commit.commitId ? `commit ${commit.commitId}` : undefined}><b>{commit.id.slice(0, 2)}</b>{commit.id.slice(2)}</span>
        <span className="gins-flags">
          {isWC && <span className="gins-flag wc">@ Working copy</span>}
          {commit.immutable && !commit.isRoot && <span className="gins-flag" title="Part of trunk history">◆ Immutable</span>}
          {commit.isEmpty && <span className="gins-flag">Empty</span>}
          {commit.isMerge && <span className="gins-flag">Merge</span>}
          {commit.hasConflict && <span className="gins-flag warn"><Ic name="conflict" size={11}/>Conflict</span>}
        </span>
        <button className="bcd-close" onClick={onClose} title="Close (Esc)" aria-label="Close"><Ic name="close" size={12}/></button>
      </header>
      <div className="gins-scroll">
      {editing && mutable ? (
        <DescribeForm commit={commit} onSave={(s, b) => { onDescribe(s, b); setEditing(false); }} onCancel={() => setEditing(false)}/>
      ) : (
        <div className={"gins-title" + (mutable ? " is-editable" : "")} onClick={mutable ? () => setEditing(true) : undefined}
          onKeyDown={mutable ? (e) => { if (e.key === "Enter") { e.preventDefault(); setEditing(true); } } : undefined}
          role={mutable ? "button" : undefined} tabIndex={mutable ? 0 : undefined} title={mutable ? "Edit description — jj describe" : undefined}>
          <h2 className={"gins-subj" + (undescribed || commit.isRoot ? " is-dim" : "")}>{undescribed && mutable ? "Describe this change…" : commit.subject}{mutable && PEN}</h2>
          {commit.description && <p className="gins-desc">{commit.description}</p>}
        </div>
      )}

      {(commit.author || when || parents.length > 0) && (
        <div className="gins-meta">
          {commit.author && <span>{commit.author}</span>}
          {when && <span>{when}</span>}
          {parents.length > 0 && <span>{parents.length > 1 ? "parents" : "parent"}&nbsp;{parents.map((p, i) => <React.Fragment key={p}>{i > 0 && " + "}<code>{p.slice(0, 8)}</code></React.Fragment>)}</span>}
        </div>
      )}
      {commit.bookmarks.length > 0 && (
        <div className="gdetail-bms gins-bms">
          {commit.bookmarks.map(b => {
            const movable = b.state !== "remote" && !b.name.includes("@");
            return (
              <span key={b.name} className={"gdetail-bm" + (movable ? " is-grab" : "")} title={STATE_LABEL[b.state] + (movable ? " · drag onto a change to move it" : "")}
                onPointerDown={movable ? (e) => beginDrag(e, { kind: "bookmark", name: b.name, from: commit.id }) : undefined}>
                <window.BookmarkGlyph filled size={11}/><span className="gins-bm-name">{b.name}</span>
                <span className={"gbm-state s-" + b.state}>{b.state === "ahead" ? `↑${b.ahead || 1}` : b.state === "synced" ? "✓" : b.state === "remote" ? "remote" : b.state === "diverged" ? "↕" : b.state === "behind" ? "↓" : "local"}</span>
              </span>
            );
          })}
        </div>
      )}
      {!editing && <div className="gins-act">{actions}</div>}

      <div className="bcd-body">
        {files.length === 0 ? (
          <div className="gch-empty">{isWC ? "No changes yet — whatever you edit in your editor lands here." : commit.isMerge ? "A merge — no changes of its own." : commit.isRoot ? "The root of all history." : "This change has no file changes."}</div>
        ) : <>
          <div className="gch-hd">
            {mutable && <Check state={allState} onToggle={() => setSel(allState === "all" ? new Set() : new Set(allIds))} label={allState === "all" ? "Deselect all" : "Select all"}/>}
            <span className="gch-title">Changes</span>
            <span className="gch-meta">{files.length} {files.length === 1 ? "file" : "files"}<span className="stat-add">+{tot.a}</span><span className="stat-rem">−{tot.r}</span></span>
            {viewedN > 0 && (
              <span className="gch-viewed" title={`${viewedN} of ${files.length} files viewed`}>
                {viewedN === files.length ? <><Ic name="check" size={10}/>all viewed</> : <>{viewedN}/{files.length} viewed</>}
                <button onClick={() => setMany(files.map(f => f.path), viewedN !== files.length)}>{viewedN === files.length ? "Reset" : "Mark all"}</button>
              </span>
            )}
          </div>
          <div className="gch-files" role="list">
            {files.map(f => {
              const st = sum(f.hunks), v = !!reviewed[f.path], lifted = liftSet && f.hunks.every(h => liftSet.has(h.id));
              return (
                <div key={f.path} role="listitem" className={"gch-file" + (ff && ff.path === f.path ? " is-focus" : "") + (v ? " is-viewed" : "") + (lifted ? " is-lifted" : "") + (mutable ? " is-grab" : "")}
                  onClick={() => setFocus(f.path)} onPointerDown={mutable ? (e) => dragFile(e, f) : undefined}
                  title={mutable ? f.path + " — drag onto a change to move it there" : f.path}>
                  {mutable && <Check state={fileState(f)} onToggle={() => toggle(f.hunks.map(h => h.id))} label={"Select " + fname(f.path)}/>}
                  <span className={"file-status status-" + f.status}>{f.status}</span>
                  <span className="file-path"><span className="file-path-inner">{f.path}</span></span>
                  {v && <span className="gch-vw" title="Viewed"><Ic name="check" size={10}/></span>}
                  <span className="file-stat">{st.a > 0 && <span className="stat-add">+{st.a}</span>}{st.r > 0 && <span className="stat-rem">−{st.r}</span>}</span>
                </div>
              );
            })}
          </div>
          {ff && (
            <div className={"diff-block gdv" + (reviewed[ff.path] ? " viewed" : "")}>
              <div className="diff-toolbar">
                <span className="diff-toolbar-file" title={ff.path}>{ff.path}</span>
                <div className="diff-mode-toggle" role="radiogroup" aria-label="Diff layout">
                  <button role="radio" aria-checked={t.diffMode !== "split"} className={t.diffMode !== "split" ? "seg active" : "seg"} onClick={() => setTweak("diffMode", "inline")} title="Unified" aria-label="Unified"><Ic name="splitInline" size={12}/></button>
                  <button role="radio" aria-checked={t.diffMode === "split"} className={t.diffMode === "split" ? "seg active" : "seg"} onClick={() => setTweak("diffMode", "split")} title="Side by side" aria-label="Side by side"><Ic name="splitSide" size={12}/></button>
                </div>
                <button className={"diff-viewed-toggle " + (reviewed[ff.path] ? "viewed " : "")} role="checkbox" aria-checked={!!reviewed[ff.path]}
                  onClick={() => setViewed(ff.path, !reviewed[ff.path])} title={reviewed[ff.path] ? "Mark as not viewed" : "Mark as viewed"}>
                  <span className={"diff-viewed-box " + (reviewed[ff.path] ? "checked " : "")}>{reviewed[ff.path] && <Ic name="check" size={10}/>}</span><span>Viewed</span>
                </button>
              </div>
              {reviewed[ff.path]
                ? <button className="diff-collapsed" onClick={() => setViewed(ff.path, false)}><Ic name="check" size={11}/><span>Viewed — diff folded away. Click to show it again.</span></button>
                : ff.hunks.map(h => (
                  <Hunk key={h.id} f={ff} h={h} mode={t.diffMode} mutable={mutable} selected={sel.has(h.id)} lifted={liftSet && liftSet.has(h.id)}
                    onToggle={() => toggle([h.id])} onDragStart={dragHunk}/>
                ))}
            </div>
          )}
        </>}
      </div>
      </div>

      {composing && <Composer commit={commit} isWC={isWC} files={files} sel={sel} subj={subj} setSubj={setSubj} body={body} setBody={setBody} valid={valid} onRun={run} onClear={() => setSel(new Set())}/>}
    </section>
  );
}

Object.assign(window, { GraphInspector });
})();
