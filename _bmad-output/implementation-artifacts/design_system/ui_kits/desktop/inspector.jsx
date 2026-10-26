// Inspector — reading and shaping one change. The title is the describe field; checkboxes pick hunks; the composer turns a selection
// into a commit (@: jj commit) or a split (jj split -r). Files, hunks and bookmarks can be dragged onto another change.
(() => {
const { Island, IconButton, Button, Flag, AtBadge, Icon, FileRow, DiffView, DiffHunk, Segmented, Checkbox, TextField, BookmarkChip, HatchSwatch } = window.ZanshinDesignSystem_a33847;
const Swatch = HatchSwatch || (() => null);
const first = (s) => (s || "").split("\n")[0].trim();
const joinMsg = (s, b) => (s.trim() + (b.trim() ? "\n\n" + b.trim() : "")).trim();
const fname = (p) => p.split("/").pop();
const VIEWED = new Map();

function ZKDescFields({ s, setS, b, setB, size = "lg", placeholder, onSubmit, onCancel, inputRef }) {
  const key = (e) => {
    if (e.key === "Escape" && onCancel) { e.preventDefault(); e.stopPropagation(); onCancel(); }
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey || e.target.tagName === "INPUT")) { e.preventDefault(); onSubmit(); }
  };
  return (
    <div className="zk-desc-fields" onKeyDown={key}>
      <TextField size={size} inputRef={inputRef} value={s} onChange={(e) => setS(e.target.value)} placeholder={placeholder || "Summary"} aria-label="Summary"/>
      <TextField multiline size={size === "md" ? "md" : undefined} value={b} onChange={(e) => setB(e.target.value)} placeholder="Details (optional)" rows={2} aria-label="Details"/>
    </div>
  );
}

function ZKDescribe({ c, onSave, onCancel }) {
  const [s, setS] = React.useState(c.subject || ""), [b, setB] = React.useState(c.description || "");
  const ref = React.useRef(null);
  React.useEffect(() => { const t = setTimeout(() => { if (ref.current) { ref.current.focus(); ref.current.select(); } }, 20); return () => clearTimeout(t); }, []);
  return (
    <div className="zk-desc">
      <ZKDescFields s={s} setS={setS} b={b} setB={setB} inputRef={ref} onSubmit={() => onSave(s, b)} onCancel={onCancel}/>
      <div className="zk-desc-ft">
        <code title={"jj describe -r " + c.id}>jj describe -r {c.id.slice(0, 8)} -m “{first(s) || "…"}”</code>
        <Button onClick={onCancel}>Cancel</Button>
        <Button variant="primary" onClick={() => onSave(s, b)}>Save</Button>
      </div>
    </div>
  );
}

function ZKComposer({ c, isWC, files, sel, onRun, onClear }) {
  const [subj, setSubj] = React.useState(""), [body, setBody] = React.useState("");
  const id8 = c.id.slice(0, 8), msg = joinMsg(subj, body);
  const selF = files.map((f) => ({ f, hs: f.hunks.filter((h) => sel.has(h.id)) })).filter((x) => x.hs.length);
  const restF = files.map((f) => ({ f, hs: f.hunks.filter((h) => !sel.has(h.id)) })).filter((x) => x.hs.length);
  const s = window.zkCount(selF.map((x) => ({ hunks: x.hs }))), r = window.zkCount(restF.map((x) => ({ hunks: x.hs })));
  const partial = selF.some((x) => x.hs.length < x.f.hunks.length), everything = !restF.length;
  const m = msg ? ' -m "' + first(msg) + (msg.includes("\n") ? "…" : "") + '"' : "";
  const paths = partial ? " -i" : isWC && everything ? "" : " " + selF.map((x) => x.f.path).join(" ");
  const cmd = isWC ? "jj commit" + m + paths : "jj split -r " + id8 + m + paths;
  const valid = sel.size > 0 && (isWC || !everything);
  const nf = (n) => n + (n === 1 ? " file" : " files");
  const stat = (x) => <span className="zk-comp-stat">{x.a > 0 && <span className="a">+{x.a}</span>}{x.r > 0 && <span className="r">−{x.r}</span>}</span>;
  const go = () => { if (valid) { onRun([...sel], msg); setSubj(""); setBody(""); } };
  return (
    <div className="zk-comp" role="group" aria-label={isWC ? "Commit" : "Split"}>
      <ZKDescFields size="md" s={subj} setS={setSubj} b={body} setB={setBody} onSubmit={go} placeholder={isWC ? "Summary of what you did" : "Summary of the selected changes"}/>
      <div className="zk-comp-result" aria-label="Result">
        <div className={"zk-comp-node is-rest" + (isWC ? " is-wc" : "")}>
          <span className="zk-comp-dot"></span>
          {isWC ? <><AtBadge size="sm"/><span className="zk-comp-l">New working copy</span></> : <span className="zk-comp-l">Rest</span>}
          <span className="zk-comp-m">{everything ? "empty" : <>{nf(restF.length)} {stat(r)}</>}</span>
          <span className="zk-comp-n">{isWC ? "stays here to keep working" : <>keeps “{first(c.subject)}”</>}</span>
        </div>
        <div className="zk-comp-node is-sel">
          <span className="zk-comp-dot"></span>
          <span className="zk-comp-l">Selected</span>
          <span className="zk-comp-m">{sel.size ? <>{nf(selF.length)} {stat(s)}</> : "nothing yet"}</span>
          <span className={"zk-comp-n" + (msg ? " is-msg" : "")}>{msg ? <>“{first(msg)}”</> : "no description yet"}</span>
        </div>
      </div>
      <div className="zk-comp-ft">
        <code className="zk-comp-cmd" title={cmd}>{cmd}</code>
        {!isWC && <Button onClick={onClear}>Cancel</Button>}
        <Button variant="primary" disabled={!valid} onClick={go} title="⌘↩">{isWC ? "Commit" : "Split"}</Button>
      </div>
      {!isWC && everything && <div className="zk-comp-hint">Everything is selected — leave something behind to split it in two.</div>}
    </div>
  );
}

function ZKInspector({ c, isWC, canSquash, diffMode, setDiffMode, editing, setEditing, lift, onClose, onEdit, onNew, onDescribe, onSquash, onAbandon, onCommit, onSplit, beginDrag }) {
  const mutable = !c.immutable;
  const undescribed = !c.subject;
  const files = c.files;
  const allIds = React.useMemo(() => files.flatMap((f) => f.hunks.map((h) => h.id)), [files]);
  const [selRaw, setSel] = React.useState(() => new Set(isWC ? allIds : []));
  const sel = React.useMemo(() => new Set([...selRaw].filter((id) => allIds.includes(id))), [selRaw, allIds]);
  const [focus, setFocus] = React.useState(files[0] && files[0].path);
  const ff = files.find((f) => f.path === focus) || files[0];
  const [viewed, setViewedMap] = React.useState(() => VIEWED.get(c.id) || {});
  const setViewed = (p, v) => setViewedMap((o) => { const n = { ...o, [p]: v }; VIEWED.set(c.id, n); return n; });
  const viewedN = files.filter((f) => viewed[f.path]).length;
  const tot = window.zkCount(files);
  const parents = [...c.parents, ...c.gapParents];
  const composing = mutable && (isWC ? files.length > 0 : sel.size > 0);
  const liftSet = lift ? new Set(lift) : null;

  React.useEffect(() => { // Esc clears a split selection before it closes the panel
    if (isWC || !sel.size || editing) return;
    const k = (e) => { if (e.key === "Escape") { e.stopImmediatePropagation(); setSel(new Set()); } };
    window.addEventListener("keydown", k, true);
    return () => window.removeEventListener("keydown", k, true);
  }, [isWC, sel.size, editing]);

  const toggle = (ids) => setSel((s) => { const n = new Set([...s].filter((id) => allIds.includes(id))); const on = ids.every((id) => n.has(id)); ids.forEach((id) => on ? n.delete(id) : n.add(id)); return n; });
  const fileState = (f) => { const k = f.hunks.filter((h) => sel.has(h.id)).length; return k === 0 ? "none" : k === f.hunks.length ? "all" : "some"; };
  const allState = sel.size === 0 ? "none" : sel.size === allIds.length ? "all" : "some";
  const payload = (ids) => {
    const set = new Set(ids), fs = files.map((f) => ({ f, hs: f.hunks.filter((h) => set.has(h.id)) })).filter((x) => x.hs.length);
    const st = window.zkCount(fs.map((x) => ({ hunks: x.hs }))), whole = fs.every((x) => x.hs.length === x.f.hunks.length);
    const label = fs.length === 1 ? (whole ? fname(fs[0].f.path) : (ids.length === 1 ? "a hunk of " : ids.length + " hunks of ") + fname(fs[0].f.path)) : whole ? fs.length + " files" : ids.length + " hunks from " + fs.length + " files";
    return { kind: "diff", from: c.id, hunkIds: ids, files: fs.map((x) => ({ path: x.f.path, status: x.f.status })), whole, a: st.a, r: st.r, label };
  };
  const dragFile = (e, f) => { const ids = f.hunks.map((h) => h.id); beginDrag(e, payload(sel.size > 1 && ids.some((id) => sel.has(id)) ? [...sel] : ids)); };
  const dragHunk = (e, h) => beginDrag(e, payload(sel.size > 1 && sel.has(h.id) ? [...sel] : [h.id]));

  const actions = !mutable
    ? [<Button key="new" variant="primary" icon="plus" iconSize="md" onClick={() => onNew(c.id)} title={"jj new " + c.id.slice(0, 8)}>New change on top</Button>]
    : [
      isWC ? <Button key="new" onClick={() => onNew(c.id)} title="jj new — leave this change as it is and start a new one">New change</Button>
        : <Button key="edit" variant={composing ? "default" : "primary"} icon={<AtBadge size="sm"/>} onClick={onEdit} title="Move the working copy here — jj edit">Edit</Button>,
      <Button key="sq" disabled={!canSquash} onClick={onSquash} title={canSquash ? "jj squash — fold into the parent" : "The parent can’t be rewritten"}>Squash into parent</Button>,
      <Button key="ab" variant="danger" className="zk-push" onClick={onAbandon} title="jj abandon">Abandon</Button>,
    ];

  return (
    <Island shape="panel" className={"zk-ins" + (composing ? " is-composing" : "")} role="complementary" aria-label="Change details" data-screen-label={"Detail " + c.id}>
      <header className="zk-ins-hd">
        <span className="zk-ins-id" title={"commit " + c.commit}><b>{c.id.slice(0, 2)}</b>{c.id.slice(2)}</span>
        <span className="zk-ins-flags">
          {isWC && <Flag kind="wc">@ Working copy</Flag>}
          {c.immutable && <Flag icon={<Swatch/>} title={c.immWhy ? "Immutable · " + c.immWhy : "Part of trunk history"}>Immutable</Flag>}
          {!files.length && !c.merge && <Flag>Empty</Flag>}
          {c.merge && <Flag>Merge</Flag>}
          {c.conflict && <Flag kind="warn" icon="conflict">Conflict</Flag>}
        </span>
        <IconButton icon="close" iconSize="sm" size="sm" label="Close" title="Close (Esc)" onClick={onClose}/>
      </header>
      <div className="zk-ins-scroll">
        {editing && mutable ? (
          <ZKDescribe c={c} onSave={(s, b) => { onDescribe(s, b); setEditing(false); }} onCancel={() => setEditing(false)}/>
        ) : (
          <div className={"zk-ins-title" + (mutable ? " is-editable" : "")} onClick={mutable ? () => setEditing(true) : undefined}
            onKeyDown={mutable ? (e) => { if (e.key === "Enter") { e.preventDefault(); setEditing(true); } } : undefined}
            role={mutable ? "button" : undefined} tabIndex={mutable ? 0 : undefined} title={mutable ? "Edit description — jj describe" : undefined}>
            <h2 className={"zk-ins-subj" + (undescribed ? " is-dim" : "")}>{undescribed ? (mutable ? "Describe this change…" : "(no description set)") : c.subject}{mutable && <Icon name="describe" size="sm" className="zk-ins-pen"/>}</h2>
            {c.description && <p className="zk-ins-desc">{c.description}</p>}
          </div>
        )}
        <div className="zk-ins-meta">
          {c.author && <span>{c.author}</span>}
          {c.date && <span>{c.date === "now" ? "just now" : c.date}</span>}
          {parents.length > 0 && <span>{parents.length > 1 ? "parents" : "parent"}&nbsp;{parents.map((p, i) => <React.Fragment key={p}>{i > 0 && " + "}<code>{p.slice(0, 8)}</code></React.Fragment>)}</span>}
        </div>
        {c.bookmarks.length > 0 && (
          <div className="zk-ins-bms">
            {c.bookmarks.map((b) => {
              const movable = b.state !== "remote" && !b.name.includes("@");
              return <BookmarkChip key={b.name} variant="tag" name={b.name} state={b.state} ahead={b.ahead} className={movable ? "is-grab" : ""}
                title={b.name + " — " + window.ZK_BM_STATE[b.state] + (movable ? " · drag onto a change to move it" : "")}
                onPointerDown={movable ? (e) => beginDrag(e, { kind: "bookmark", name: b.name, from: c.id }) : undefined}/>;
            })}
          </div>
        )}
        {!editing && <div className="zk-ins-act">{actions}</div>}
        <div className="zk-ins-body">
          {files.length === 0 ? (
            <div className="zk-ch-empty">{isWC ? "No changes yet — whatever you edit in your editor lands here." : c.merge ? "A merge — no changes of its own." : "This change has no file changes."}</div>
          ) : <>
            <div className="zk-ch-hd">
              {mutable && <Checkbox checked={allState === "all"} mixed={allState === "some"} onChange={() => setSel(allState === "all" ? new Set() : new Set(allIds))} label={allState === "all" ? "Deselect all" : "Select all"}/>}
              <span className="zk-ch-title">Changes</span>
              <span className="zk-ch-meta">{files.length} {files.length === 1 ? "file" : "files"}<span className="a">+{tot.a}</span><span className="r">−{tot.r}</span></span>
              {viewedN > 0 && (
                <span className="zk-ch-viewed" title={viewedN + " of " + files.length + " files viewed"}>
                  {viewedN === files.length ? <><Icon name="check" size="xs"/>all viewed</> : <>{viewedN}/{files.length} viewed</>}
                  <button type="button" onClick={() => files.forEach((f) => setViewed(f.path, viewedN !== files.length))}>{viewedN === files.length ? "Reset" : "Mark all"}</button>
                </span>
              )}
            </div>
            <div className="zk-ch-files" role="list">
              {files.map((f) => {
                const st = window.zkCount([f]), state = fileState(f), lifted = liftSet && f.hunks.every((h) => liftSet.has(h.id));
                return <FileRow key={f.path} status={f.status} path={f.path} added={st.a} removed={st.r} selected={ff && ff.path === f.path} viewed={!!viewed[f.path]} lifted={!!lifted}
                  selectable={mutable} checked={state === "all"} mixed={state === "some"} onCheck={() => toggle(f.hunks.map((h) => h.id))}
                  onClick={() => setFocus(f.path)} onPointerDown={mutable ? (e) => dragFile(e, f) : undefined}
                  title={mutable ? f.path + " — drag onto a change to move it there" : f.path}/>;
              })}
            </div>
            {ff && (
              <DiffView file={ff.path} viewed={!!viewed[ff.path]} onViewedChange={(v) => setViewed(ff.path, v)}
                tools={<Segmented size="sm" label="Diff layout" value={diffMode} onChange={setDiffMode} options={[{ value: "unified", icon: "split-inline", title: "Unified" }, { value: "split", icon: "split-side", title: "Side by side" }]}/>}>
                {ff.hunks.map((h) => (
                  <DiffHunk key={h.id} oldStart={h.oldStart} newStart={h.newStart} context={h.ctx} lines={h.lines} mode={diffMode}
                    selectable={mutable} selected={sel.has(h.id)} lifted={!!(liftSet && liftSet.has(h.id))} onToggle={() => toggle([h.id])}
                    onGrab={mutable ? (e) => dragHunk(e, h) : undefined}/>
                ))}
              </DiffView>
            )}
          </>}
        </div>
      </div>
      {composing && <ZKComposer key={c.id + (isWC ? "w" : "s")} c={c} isWC={isWC} files={files} sel={sel}
        onRun={(ids, msg) => { (isWC ? onCommit : onSplit)(ids, msg); setSel(new Set()); }} onClear={() => setSel(new Set())}/>}
    </Island>
  );
}

Object.assign(window, { ZKInspector });
})();
