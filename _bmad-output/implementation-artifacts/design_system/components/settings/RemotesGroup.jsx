import React from "react";
import { SettingsGroup } from "./SettingsGroup.jsx";
import { Icon } from "../brand/Icon.jsx";
import { IconButton } from "../actions/IconButton.jsx";
import { Button } from "../actions/Button.jsx";
import { TextField } from "../forms/TextField.jsx";
import { Menu } from "../menus/Menu.jsx";
import { ConfirmDialog } from "../controls/ConfirmDialog.jsx";

// RemotesGroup — Settings › Project › Remotes (sync #20): the git remotes (jj git remote list), then the group's other rows (children:
// Fetch from · Push to · Fetch automatically). A row: the name, the fetch URL (mono, one line, ellipsis — the window is resizable), the
// push URL when it differs. ••• → Rename… · Set URL… · Remove…; "Add remote…" is the list's last row. Rename, Set URL and Add edit IN the
// row (the Projects window's in-place rename grown to a small form): fields, the exact command, Cancel + the verb; ↩ runs, Esc cancels.
// Remove asks first (ConfirmDialog, a sheet on the Settings window): git forgets the URLs and jj undo can't bring them back.
// A credential never shows — rows, fields, commands, tooltips hide everything between "scheme://" and "@".
// onRun(op) runs the jj verb and returns null, { refusal: { message, help } } (jj's text verbatim + one plain sentence) or { warning }.
const zsRemScrub = (u) => (u == null ? u : u.replace(/^([a-z][a-z0-9+.-]*:\/\/)[^/@]+@/i, "$1•••@"));
const zsRemCred = (u) => u != null && zsRemScrub(u) !== u;
const zsSh = (s) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'");
// set-url sends only the sides that change; an empty field leaves its side alone (jj can set a URL, not remove one)
const zsRemSide = (v, was) => { const t = (v || "").trim(); return t && t !== was ? t : null; };
function zsRemOp(f, r) {
  if (f.mode === "add") return { verb: "add", name: f.name.trim(), url: f.url.trim(), pushUrl: f.push.trim() || null };
  if (f.mode === "rename") return { verb: "rename", name: f.of, newName: f.name.trim() };
  if (f.mode === "url") return { verb: "set-url", name: f.of, url: zsRemSide(f.url, r && r.url), pushUrl: zsRemSide(f.push, r && (r.pushUrl || r.url)) };
  return { verb: "remove", name: f.of };
}
function zsRemCommand(op) {
  const a = ["jj git remote", op.verb];
  if (op.verb === "add") { a.push(zsSh(op.name || "<name>"), zsSh(zsRemScrub(op.url) || "<url>")); if (op.pushUrl) a.push("--push-url", zsSh(zsRemScrub(op.pushUrl))); }
  else if (op.verb === "rename") a.push(zsSh(op.name), zsSh(op.newName || "<new name>"));
  else if (op.verb === "set-url") { a.push(zsSh(op.name)); if (op.url) a.push(zsSh(zsRemScrub(op.url))); if (op.pushUrl) a.push("--push", zsSh(zsRemScrub(op.pushUrl))); }
  else a.push(zsSh(op.name));
  return a.join(" ");
}

function ZsRemRefusal({ refusal }) {
  return (
    <div className="zs-rem-err" role="alert">
      <span className="zs-rem-err-msg"><Icon name="conflict" size="sm" />{refusal.message}</span>
      {refusal.help && <span className="zs-rem-help">{refusal.help}</span>}
    </div>
  );
}

function ZsRemForm({ f, setF, remote, onRun, onCancel }) {
  const first = React.useRef(null);
  React.useEffect(() => { const el = first.current; if (el) { el.focus(); if (f.mode === "rename") el.select(); } }, []);
  const op = zsRemOp(f, remote);
  const ok = f.mode === "add" ? op.name && op.url : f.mode === "rename" ? op.newName && op.newName !== f.of : !!(op.url || op.pushUrl);
  const onKey = (e) => {
    if (e.key === "Enter") { e.preventDefault(); if (ok) onRun(); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onCancel(); }
  };
  const field = (k, label, o = {}) => (
    <label className="zs-rem-f">
      <span className="zs-rem-fl">{label}</span>
      <span className="zs-rem-fc">
        <TextField size="sm" mono={o.mono} inputRef={o.first ? first : undefined} value={f[k]} placeholder={o.placeholder} error={!!(o.marks && f.refusal)}
          onChange={(e) => setF({ ...f, [k]: e.target.value, refusal: null })} spellCheck={false} autoComplete="off" aria-label={label} />
        {o.hint && <span className="zs-rem-fh">{o.hint}</span>}
      </span>
    </label>
  );
  const cred = (u) => (zsRemCred(u) ? zsRemScrub(u) : "");
  return (
    <div className="zs-rem-form" onKeyDown={onKey}>
      {f.mode === "add" && <>
        {field("name", "Name", { first: true, placeholder: "upstream", marks: true })}
        {field("url", "URL", { mono: true, placeholder: "https://github.com/owner/repo.git" })}
        {field("push", "Push URL", { mono: true, placeholder: "Same as URL", hint: "Optional. jj can’t remove a remote with a push URL later — git remote remove can." })}
      </>}
      {f.mode === "rename" && field("name", "New name", { first: true, marks: true, hint: "Its remote bookmarks follow: main@" + f.of + " becomes main@" + (f.name.trim() || "…") + "." })}
      {f.mode === "url" && <>
        {field("url", "URL", { first: true, mono: true, placeholder: cred(remote.url), hint: zsRemCred(remote.url) ? "Holds a credential, so it stays hidden. Type a new URL to replace it." : null })}
        {field("push", "Push URL", { mono: true, placeholder: remote.pushUrl ? cred(remote.pushUrl) : "Same as URL", hint: remote.pushUrl ? "Empty leaves it as it is: jj can set a push URL, not remove one." : null })}
      </>}
      <code className="zs-rem-cmd">{zsRemCommand(op)}</code>
      {f.refusal && <ZsRemRefusal refusal={f.refusal} />}
      <div className="zs-rem-btns">
        <Button size="md" onClick={onCancel}>Cancel</Button>
        <Button size="md" variant="primary" disabled={!ok} onClick={onRun} title="↩">{{ add: "Add", rename: "Rename", url: "Set URL" }[f.mode]}</Button>
      </div>
    </div>
  );
}

export function RemotesGroup({ remotes = [], onRun, initialForm = null, initialNotes = {}, children, className = "" }) {
  const [form, setForm] = React.useState(initialForm);   // { mode: add | rename | url, of, name, url, push, refusal }
  const [menu, setMenu] = React.useState(null);          // the remote whose ••• is open
  const [confirm, setConfirm] = React.useState(null);    // the remote Remove… asks about
  const [notes, setNotes] = React.useState(initialNotes); // name → { refusal } | { warning }, until the next verb
  const open = (mode, r) => {
    setNotes({}); setMenu(null);
    setForm({ mode, of: r ? r.name : null, name: mode === "rename" ? r.name : "", url: mode === "url" && !zsRemCred(r.url) ? r.url || "" : "",
      push: mode === "url" && r.pushUrl && !zsRemCred(r.pushUrl) ? r.pushUrl : "", refusal: null });
  };
  const run = () => {
    const op = zsRemOp(form, remotes.find((x) => x.name === form.of));
    const res = onRun ? onRun(op) : null;
    if (res && res.refusal) { setForm({ ...form, refusal: res.refusal }); return; }
    setForm(null); setNotes(res && res.warning ? { [op.name]: { warning: res.warning } } : {});
  };
  const remove = (name) => {
    const res = onRun ? onRun({ verb: "remove", name }) : null;
    setConfirm(null);
    setNotes(res && res.refusal ? { [name]: { refusal: res.refusal } } : {});
  };
  const editing = (r) => form && form.mode !== "add" && form.of === r.name;
  return (
    <SettingsGroup title="Remotes" className={("zs-rem " + className).trim()}>
      {remotes.length === 0 && !form && <div className="zs-setrow zs-rem-empty">No remotes yet. Fetch and push need one.</div>}
      {remotes.map((r) => editing(r) ? (
        <div key={r.name} className="zs-setrow is-stack zs-rem-row is-editing">
          <div className="zs-rem-head"><span className="zs-rem-name">{r.name}</span><span className="zs-rem-what">{form.mode === "rename" ? "Rename" : "Set URL"}</span></div>
          <ZsRemForm f={form} setF={setForm} remote={r} onRun={run} onCancel={() => setForm(null)} />
        </div>
      ) : (
        <div key={r.name} className="zs-setrow zs-rem-row">
          <div className="zs-setrow-lbl zs-rem-lbl">
            <span className="zs-rem-name">{r.name}</span>
            <span className="zs-rem-url" title={r.url ? zsRemScrub(r.url) : undefined}>{r.url ? zsRemScrub(r.url) : <i>No fetch URL</i>}</span>
            {r.pushUrl && <span className="zs-rem-url" title={zsRemScrub(r.pushUrl)}><span className="zs-rem-k">push</span>{zsRemScrub(r.pushUrl)}</span>}
            {notes[r.name] && notes[r.name].refusal && <ZsRemRefusal refusal={notes[r.name].refusal} />}
            {notes[r.name] && notes[r.name].warning && (
              <span className="zs-rem-warn"><Icon name="conflict" size="sm" />{notes[r.name].warning.message}{notes[r.name].warning.hint && <span className="zs-rem-hint">{notes[r.name].warning.hint}</span>}</span>
            )}
          </div>
          <div className="zs-setrow-ctl zs-rem-more">
            <IconButton icon="more" label={"More for " + r.name} size="sm" active={menu === r.name} aria-haspopup="menu" aria-expanded={menu === r.name}
              onClick={() => setMenu(menu === r.name ? null : r.name)} />
            {menu === r.name && (
              <Menu autoFocus items={[{ id: "rename", text: "Rename…", cmd: "jj git remote rename" }, { id: "url", text: "Set URL…", cmd: "jj git remote set-url" }, "sep",
                { id: "remove", text: "Remove…", cmd: "jj git remote remove" }]}
                onSelect={(id) => { setMenu(null); if (id === "remove") { setNotes({}); setConfirm(r.name); } else open(id, r); }} onClose={() => setMenu(null)} />
            )}
          </div>
        </div>
      ))}
      {form && form.mode === "add" ? (
        <div className="zs-setrow is-stack zs-rem-row is-editing">
          <div className="zs-rem-head"><span className="zs-rem-name">Add remote</span></div>
          <ZsRemForm f={form} setF={setForm} onRun={run} onCancel={() => setForm(null)} />
        </div>
      ) : (
        <button type="button" className="zs-setrow is-nav zs-rem-add" onClick={() => open("add")} title="jj git remote add"><span className="zs-rem-add-l"><Icon name="plus" size="sm" />Add remote…</span></button>
      )}
      {children}
      {confirm && (
        <ConfirmDialog title={"Remove " + confirm + "?"} confirmLabel="Remove remote" cmd={zsRemCommand({ verb: "remove", name: confirm })} onConfirm={() => remove(confirm)} onCancel={() => setConfirm(null)}>
          Its remote bookmarks (<code>{"main@" + confirm}</code> and the rest) leave this repository and git forgets its URLs. Your own bookmarks and changes stay. <code>jj undo</code> can’t bring the URLs back.
        </ConfirmDialog>
      )}
    </SettingsGroup>
  );
}
RemotesGroup.scrub = zsRemScrub;
RemotesGroup.command = zsRemCommand;
