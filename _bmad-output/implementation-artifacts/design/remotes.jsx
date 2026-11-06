/* global React */
// REMOTES — Settings › Project › Remotes (sync #20, Story 11.18): the list, then Fetch from / Push to / Fetch automatically.
// A row: name, fetch URL (mono, one line, ellipsis — the window widens), the push URL when it differs. ••• opens Rename… · Set URL… ·
// Remove…; Add remote… is the group's last list row. Rename, Set URL and Add edit IN the row (the Projects window's in-place rename,
// grown to a small form): fields, the exact command (shell-quoted, credentials hidden), Cancel + the verb; ↩ runs it, Esc cancels.
// Remove asks first (ConfirmDialog as a sheet on the Settings window: git forgets the URLs, jj undo can't bring them back).
// jj's refusal shows under the row, verbatim, with one plain sentence where jj's words need one. No undo toast: jj undo would revert
// the remote bookmarks but not git's config.
(() => {
const { useState, useEffect, useRef } = React;
const Ic = (p) => <window.Icon {...p}/>;

// ---------- mock store (per project; the app reads RepoHandle.remotes after every verb) ----------
const SEED = [
  { name: "origin", url: "git@github.com:ralph/myapp.git", pushUrl: null },
  { name: "upstream", url: "https://github.com/acme-platform/myapp-monorepo-with-a-rather-long-name.git", pushUrl: "git@github.com:ralph/myapp-monorepo-with-a-rather-long-name.git" },
  { name: "mirror", url: "https://ralph:ghp_8f3kQ2xVn7tLw0@git.example.com/team/myapp.git", pushUrl: null },
];
function useRemotes(pid) {
  const key = "zanshin.remotes." + (pid || "_");
  const [list, setList] = useState(() => { try { const s = localStorage.getItem(key); return s ? JSON.parse(s) : SEED; } catch { return SEED; } });
  useEffect(() => { try { localStorage.setItem(key, JSON.stringify(list)); } catch {} }, [key, list]);
  return [list, setList];
}

// a credential never shows: everything between "scheme://" and "@" is hidden (rows, fields, commands, tooltips)
const scrub = (u) => u == null ? u : u.replace(/^([a-z][a-z0-9+.-]*:\/\/)[^/@]+@/i, "$1•••@");
const hasCred = (u) => u != null && scrub(u) !== u;
const sh = (s) => /^[A-Za-z0-9_@%+=:,./-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'";
const cmdOf = (f, list) => {
  const a = ["jj", "git", "remote"];
  if (f.mode === "add") { a.push("add", sh(f.name.trim() || "<name>"), sh(scrub(f.url.trim()) || "<url>")); if (f.push.trim()) a.push("--push-url", sh(scrub(f.push.trim()))); }
  if (f.mode === "rename") a.push("rename", sh(f.of), sh(f.name.trim() || "<new name>"));
  if (f.mode === "url") {
    const r = list.find(x => x.name === f.of), u = urlChange(f, r), p = pushChange(f, r);
    a.push("set-url", sh(f.of)); if (u) a.push(sh(scrub(u))); if (p) a.push("--push", sh(scrub(p)));
  }
  if (f.mode === "remove") a.push("remove", sh(f.of));
  return a.join(" ");
};
// set-url sends only the sides that change; an empty field leaves its side alone (jj can't remove a URL)
const urlChange = (f, r) => { const v = f.url.trim(); return v && r && v !== r.url ? v : null; };
const pushChange = (f, r) => { const v = f.push.trim(); return v && r && v !== (r.pushUrl || r.url) ? v : null; };

// what jj answers (the bridge runs the verb; these are jj-lib's messages, verbatim)
function run(f, list) {
  const exists = (n) => list.some(x => x.name === n);
  const reserved = (n) => n === "git" && { msg: "Git remote named 'git' is reserved for local Git repository", help: "jj uses the name git for the repository on disk. Pick another name." };
  if (f.mode === "add") {
    const n = f.name.trim();
    const err = reserved(n) || (exists(n) && { msg: "Git remote named '" + n + "' already exists" });
    if (err) return { err };
    const push = f.push.trim() || null, url = f.url.trim();
    const same = list.find(x => x.url === url || x.pushUrl === url || (push && (x.url === push || x.pushUrl === push)));
    return { list: [...list, { name: n, url, pushUrl: push && push !== url ? push : null }],
      warn: same && { of: n, msg: "Remote " + same.name + " already uses the same URL.", hint: "If this was a mistake, run `jj git remote remove " + n + "`." } };
  }
  if (f.mode === "rename") {
    const n = f.name.trim();
    const err = reserved(n) || (exists(n) && { msg: "Git remote named '" + n + "' already exists" });
    return err ? { err } : { list: list.map(x => x.name === f.of ? { ...x, name: n } : x) };
  }
  if (f.mode === "url") {
    const r = list.find(x => x.name === f.of), u = urlChange(f, r) || r.url, p = pushChange(f, r) || r.pushUrl;
    return { list: list.map(x => x.name === f.of ? { ...x, url: u, pushUrl: p && p !== u ? p : null } : x) };
  }
  if (f.mode === "remove") {
    const r = list.find(x => x.name === f.of);
    // jj removes only a remote whose git config holds url, fetch and tagOpt — a pushurl (e.g. from add --push-url) is "nonstandard"
    if (r.pushUrl) return { err: { msg: "Git remote named '" + r.name + "' has nonstandard configuration",
      help: <>Its git config has entries jj doesn’t manage, such as a push URL, so jj leaves it alone. <code>{"git remote remove " + r.name}</code> removes it.</> } };
    return { list: list.filter(x => x.name !== f.of) };
  }
}

// ---------- the row's form (Add · Rename · Set URL) ----------
function RemoteForm({ f, setF, list, onRun, onCancel }) {
  const first = useRef(null);
  useEffect(() => { const el = first.current; if (el) { el.focus(); if (f.mode === "rename") el.select(); } }, []);
  const r = list.find(x => x.name === f.of);
  const ok = f.mode === "add" ? f.name.trim() && f.url.trim()
    : f.mode === "rename" ? f.name.trim() && f.name.trim() !== f.of
    : !!(urlChange(f, r) || pushChange(f, r));
  const key = (e) => {
    if (e.key === "Enter") { e.preventDefault(); if (ok) onRun(); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onCancel(); }
  };
  const field = (k, label, opts = {}) => (
    <label className="grem-f">
      <span className="grem-fl">{label}</span>
      <span className="grem-fc">
        <input ref={opts.first ? first : undefined} className={"gset-in" + (opts.mono ? " is-code" : "")} value={f[k]} placeholder={opts.ph || ""}
          onChange={e => setF({ ...f, [k]: e.target.value, err: null })} spellCheck={false} autoComplete="off" aria-invalid={!!(f.err && opts.errField)}/>
        {opts.hint && <span className="grem-fh">{opts.hint}</span>}
      </span>
    </label>
  );
  const verb = { add: "Add", rename: "Rename", url: "Set URL" }[f.mode];
  return (
    <div className="grem-form" onKeyDown={key}>
      {f.mode === "add" && <>
        {field("name", "Name", { first: true, ph: "upstream", errField: true })}
        {field("url", "URL", { mono: true, ph: "https://github.com/owner/repo.git" })}
        {field("push", "Push URL", { mono: true, ph: "Same as URL", hint: "Optional. jj can’t remove a remote with a push URL later — git remote remove can." })}
      </>}
      {f.mode === "rename" && field("name", "New name", { first: true, errField: true, hint: "Its remote bookmarks follow: main@" + f.of + " becomes main@" + (f.name.trim() || "…") + "." })}
      {f.mode === "url" && <>
        {field("url", "URL", { first: true, mono: true, ph: hasCred(r.url) ? scrub(r.url) : "", hint: hasCred(r.url) ? "Holds a credential, so it stays hidden. Type a new URL to replace it." : null })}
        {field("push", "Push URL", { mono: true, ph: r.pushUrl ? (hasCred(r.pushUrl) ? scrub(r.pushUrl) : "") : "Same as URL",
          hint: r.pushUrl ? "Empty leaves it as it is: jj can set a push URL, not remove one." : null })}
      </>}
      <code className="grem-cmd">{cmdOf(f, list)}</code>
      {f.err && <Refusal err={f.err}/>}
      <div className="grem-btns">
        <button className="rsd-btn" onClick={onCancel}>Cancel</button>
        <button className="rsd-btn primary" disabled={!ok} onClick={onRun} title="↩">{verb}</button>
      </div>
    </div>
  );
}
const Refusal = ({ err }) => (
  <div className="grem-err" role="alert">
    <span className="grem-err-msg"><Ic name="conflict" size={12}/>{err.msg}</span>
    {err.help && <span className="grem-help">{err.help}</span>}
  </div>
);

// ---------- the sheet on the Settings window (DS ConfirmDialog, destructive) ----------
function ConfirmSheet({ title, children, cmd, confirmLabel, onConfirm, onCancel }) {
  const cancel = useRef(null);
  useEffect(() => { cancel.current && cancel.current.focus(); }, []);
  const key = (e) => {
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onCancel(); }
    else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); onConfirm(); }
  };
  return (
    <div className="gconf-scrim" onKeyDown={key}>
      <div className="gconf" role="alertdialog" aria-modal="true" aria-label={title}>
        <h2 className="gconf-title">{title}</h2>
        <div className="gconf-body">{children}</div>
        {cmd && <code className="gconf-cmd">{cmd}</code>}
        <div className="gconf-ft">
          <span className="gconf-key">⌘↩ confirms</span>
          <button ref={cancel} className="rsd-btn" onClick={onCancel}>Cancel</button>
          <button className="rsd-btn danger" onClick={onConfirm} title="⌘↩">{confirmLabel}</button>
        </div>
      </div>
    </div>
  );
}

// ---------- the group ----------
function RemotesGroup({ list, setList, children }) {
  const [form, setForm] = useState(null);        // { mode, of, name, url, push, err }
  const [menu, setMenu] = useState(null);        // { r, x, y }
  const [confirm, setConfirm] = useState(null);  // remote name
  const [notes, setNotes] = useState({});        // name → { err } | { warn } shown under the row until the next verb
  const open = (mode, r) => { setNotes({}); setForm({ mode, of: r ? r.name : null, name: mode === "rename" ? r.name : "", url: mode === "url" && !hasCred(r.url) ? r.url || "" : "", push: mode === "url" && r.pushUrl && !hasCred(r.pushUrl) ? r.pushUrl : "", err: null }); };
  const go = () => {
    const res = run(form, list);
    if (res.err) { setForm({ ...form, err: res.err }); return; }
    setList(res.list); setForm(null); setNotes(res.warn ? { [res.warn.of]: { warn: res.warn } } : {});
  };
  const remove = (name) => {
    const res = run({ mode: "remove", of: name }, list);
    setConfirm(null);
    if (res.err) setNotes({ [name]: { err: res.err } }); else { setList(res.list); setNotes({}); }
  };
  const more = (e, r) => {
    const b = e.currentTarget.getBoundingClientRect();
    setMenu({ r, x: b.right - 200, y: b.bottom + 4 });
  };
  const RowMenu = window.RowMenu;
  return (
    <section className="gset-grp"><h3>Remotes</h3><div className="gset-box">
      {list.length === 0 && !form && <div className="gset-row grem-empty">No remotes yet. Fetch and push need one.</div>}
      {list.map(r => form && form.of === r.name ? (
        <div key={r.name} className="gset-row is-stack grem-row is-editing">
          <div className="grem-head"><span className="grem-name">{r.name}</span><span className="grem-what">{form.mode === "rename" ? "Rename" : "Set URL"}</span></div>
          <RemoteForm f={form} setF={setForm} list={list} onRun={go} onCancel={() => setForm(null)}/>
        </div>
      ) : (
        <div key={r.name} className="gset-row grem-row">
          <div className="gset-lbl grem-lbl">
            <span className="grem-name">{r.name}</span>
            <span className="grem-url" title={scrub(r.url) || "No fetch URL"}>{r.url ? scrub(r.url) : <i>No fetch URL</i>}</span>
            {r.pushUrl && <span className="grem-url" title={scrub(r.pushUrl)}><span className="grem-k">push</span>{scrub(r.pushUrl)}</span>}
            {notes[r.name] && notes[r.name].err && <Refusal err={notes[r.name].err}/>}
            {notes[r.name] && notes[r.name].warn && <span className="grem-warn"><Ic name="conflict" size={12}/>{notes[r.name].warn.msg} <span className="grem-hint">{notes[r.name].warn.hint}</span></span>}
          </div>
          <div className="gset-ctl">
            <button className="grem-more" onClick={(e) => more(e, r)} title="More…" aria-label={"More for " + r.name} aria-haspopup="menu"><Ic name="more" size={13}/></button>
          </div>
        </div>
      ))}
      {form && form.mode === "add" ? (
        <div className="gset-row is-stack grem-row is-editing">
          <div className="grem-head"><span className="grem-what">Add remote</span></div>
          <RemoteForm f={form} setF={setForm} list={list} onRun={go} onCancel={() => setForm(null)}/>
        </div>
      ) : (
        <button className="gset-row gset-nav grem-add" onClick={() => open("add")} title="jj git remote add"><span className="grem-add-l"><Ic name="plus" size={12}/>Add remote…</span></button>
      )}
      {children}
    </div>
      {menu && RowMenu && <RowMenu x={menu.x} y={menu.y} onClose={() => setMenu(null)} items={[
        { label: "Rename…", onSelect: () => open("rename", menu.r) },
        { label: "Set URL…", onSelect: () => open("url", menu.r) },
        "sep",
        { label: "Remove…", onSelect: () => { setNotes({}); setConfirm(menu.r.name); } },
      ]}/>}
      {confirm && (
        <ConfirmSheet title={"Remove " + confirm + "?"} confirmLabel="Remove remote" cmd={cmdOf({ mode: "remove", of: confirm }, list)} onConfirm={() => remove(confirm)} onCancel={() => setConfirm(null)}>
          Its remote bookmarks (<code>{"main@" + confirm}</code> and the rest) leave this repository and git forgets its URLs. Your own bookmarks and changes stay. <code>jj undo</code> can’t bring the URLs back.
        </ConfirmSheet>
      )}
    </section>
  );
}

Object.assign(window, { useRemotes, RemotesGroup, ConfirmSheet, scrubRemoteUrl: scrub });
})();
