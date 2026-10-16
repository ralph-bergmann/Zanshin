import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Switch } from "../forms/Switch.jsx";
import { Segmented } from "../forms/Segmented.jsx";
import { Select } from "../forms/Select.jsx";
import { useSheetFocus } from "../surfaces/Dialog.jsx";
import { Window } from "../window/Window.jsx";
import { ConfirmDialog } from "../controls/ConfirmDialog.jsx";

const zsCopiedMs = () => { try { const n = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--dur-copied")); return isNaN(n) ? 1200 : n; } catch (e) { return 1200; } };
const ZS_RSD_FNS = ["author", "committer", "mine", "subject", "description", "files"];
const ZS_RSD_HINT = { author: "Author name or email", committer: "Committer name or email", mine: "Changes authored by your user.email", subject: "First line of the description", description: "Full description text", files: "Changes touching these paths" };
const ZS_RSD_TEXT = [["substring", "contains"], ["exact", "is exactly"], ["glob", "matches glob"], ["regex", "matches regex"]];
const ZS_RSD_FILE = [["prefix", "path or folder"], ["file", "exact file"], ["glob", "glob"]];
const zsRsdQ = (v) => '"' + String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
function zsRuleExpr(r) {
  let e;
  if (r.fn === "mine") e = "mine()";
  else if (r.fn === "files") e = "files(" + (r.mode === "prefix" ? "" : r.mode + ":") + zsRsdQ(r.value) + ")";
  else e = r.fn + "(" + r.mode + (r.ci ? "-i" : "") + ":" + zsRsdQ(r.value) + ")";
  return (r.not ? "~" : "") + e;
}
function zsExprOf(cfg) {
  if (!cfg.rules) return cfg.expr || "all()";
  const rs = cfg.rules.filter((r) => r.fn === "mine" || String(r.value || "").trim());
  return rs.length ? rs.map(zsRuleExpr).join(cfg.op === "|" ? " | " : " & ") : "all()";
}
const zsNewRule = (fn) => (fn === "mine" ? { fn, not: false } : fn === "files" ? { fn, mode: "prefix", value: "", not: false } : { fn, mode: "substring", ci: false, value: "", not: false });
const zsRsdId = () => "c-" + Math.random().toString(36).slice(2, 8);

// RevsetDialog — "jj log Configurations" (the floating client's dialog, withHome). Built-ins (jj log, all()) are selectable and read-only;
// custom configurations combine filters (author, committer, mine, subject, description, files). Every entry has a Default search switch:
// the default is listed first in the search menu and ✕ in the search field returns to it; it carries a Default tag in the list.
// jj log is the fallback default — its switch is locked on while it is the default; removing the default configuration falls back to it.
// Controlled: configs/selected/defaultId come in, onChange/onSelect/onDefaultChange go out; Cancel · Apply (dirty) · OK.
// A WINDOW of its own (Window scaffold, as Settings and Projects), not a sheet: you write a filter while looking things up in the graph.
// 880 × 580 by default, resizable (min 680 × 460), the list stays 240 and the editor grows; close and zoom active, minimise grey. It floats
// above the project window while Zanshin is active, moves freely and closes with the project window. Count, mine() and Apply / OK refer to
// the project in the project window (`project`). ↩ outside the fields = OK · Esc, ⌘W and the red button = Cancel — with unsaved changes
// it asks first ("Discard changes?", a sheet on this window). active false = the graph is key (tokens/inactive.css).
export function RevsetDialog({ builtins = RevsetDialog.builtins, configs = [], selected, defaultId = "default", me = "you", matchCount, total, dirty = false,
  active = true, project, width = 880, height = 580, onZoom, discarding, onDiscarding, docHref = "https://docs.jj-vcs.dev/latest/revsets/", onSelect, onDefaultChange, onChange, onCancel, onApply, onOk, onClose, className = "", style }) {
  const [copied, setCopied] = React.useState(false);
  const sheet = React.useRef(null);
  useSheetFocus(sheet, ".zs-rsd-item.is-on");
  const cur = configs.find((c) => c.id === selected) || null;
  const curB = !cur ? builtins.find((b) => b.id === selected) || null : null;
  const home = defaultId === "default" || defaultId === "all" || configs.some((c) => c.id === defaultId) ? defaultId : "default";
  const isHome = selected === home, lockHome = isHome && selected === "default";
  const [askLocal, setAskLocal] = React.useState(false);
  const ask = discarding != null ? discarding : askLocal;
  const setAsk = (v) => (onDiscarding ? onDiscarding(v) : setAskLocal(v));
  const leave = onCancel || onClose;
  const cancel = () => { if (dirty) setAsk(true); else if (leave) leave(); };
  const discard = () => { setAsk(false); if (leave) leave(); };
  const onKey = (e) => {
    if (ask) return;
    const mod = e.metaKey || e.ctrlKey;
    if (e.key === "Escape" || (mod && e.key.toLowerCase() === "w")) { e.preventDefault(); e.stopPropagation(); cancel(); }
    else if (e.key === "Enter" && !mod && !e.target.closest('input,textarea,[contenteditable="true"],[role="listbox"],[aria-expanded="true"]')) { e.preventDefault(); e.stopPropagation(); if (onOk) onOk(); }
  };
  const set = (next, sel) => { if (onChange) onChange(next); if (sel !== undefined && onSelect) onSelect(sel); };
  const upd = (fn) => set(configs.map((c) => (c.id === selected ? fn(JSON.parse(JSON.stringify(c))) : c)));
  const updRule = (i, patch) => upd((c) => {
    const r = { ...c.rules[i], ...patch };
    if (patch.fn && patch.fn !== c.rules[i].fn) Object.assign(r, zsNewRule(patch.fn), { not: c.rules[i].not, value: patch.fn === "mine" ? undefined : c.rules[i].value });
    c.rules[i] = r; return c;
  });
  const add = () => { const c = { id: zsRsdId(), name: "New configuration", op: "&", rules: [zsNewRule("files")] }; set([...configs, c], c.id); };
  const dup = () => { if (!cur) return; const i = configs.indexOf(cur), c = { ...JSON.parse(JSON.stringify(cur)), id: zsRsdId(), name: cur.name + " copy" }; set([...configs.slice(0, i + 1), c, ...configs.slice(i + 1)], c.id); };
  const del = () => {
    if (!cur) return;
    const i = configs.indexOf(cur), rest = configs.filter((x) => x !== cur);
    if (home === cur.id && onDefaultChange) onDefaultChange("default");
    set(rest, rest.length ? rest[Math.min(i, rest.length - 1)].id : null);
  };
  const move = (dir) => { const i = cur ? configs.indexOf(cur) : -1, j = i + dir; if (i < 0 || j < 0 || j >= configs.length) return; const n = [...configs]; [n[i], n[j]] = [n[j], n[i]]; set(n); };
  const cmd = cur ? "jj log -r '" + zsExprOf(cur) + "'" : curB ? curB.cmd : "";
  const copy = () => { if (!cmd) return; try { navigator.clipboard.writeText(cmd); } catch (e) { /* clipboard unavailable */ } setCopied(true); setTimeout(() => setCopied(false), zsCopiedMs()); };
  const tag = (id) => home === id && <span className="zs-rsd-tag">Default</span>;
  const idx = cur ? configs.indexOf(cur) : -1;
  const homeUI = (
    <label className="zs-rsd-opt">
      <span className="zs-rsd-opt-t"><span>Default search</span><span className="zs-rsd-dim">{lockHome ? "Used whenever no other configuration is the default" : "Listed first in the search menu — ✕ in the search field returns to it"}</span></span>
      <Switch label="Default search" checked={isHome} disabled={lockHome} onChange={() => onDefaultChange && onDefaultChange(isHome ? "default" : selected)}/>
    </label>
  );
  const preview = (
    <div className="zs-rsd-block">
      <span className="zs-rsd-lbl">Command</span>
      <div className="zs-rsd-pv">
        <div className="zs-rsd-pv-cmd"><span className="zs-rsd-prompt">❯ </span>{cmd}</div>
        <div className="zs-rsd-pv-ft">
          <span>{matchCount != null && <><b>{matchCount}</b>{total != null ? " of " + total : ""} changes match{project && <> in <span className="zs-rsd-proj">{project}</span></>}</>}</span>
          <button type="button" className="zs-rsd-link" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
        </div>
      </div>
    </div>
  );
  const box = (
    <div ref={sheet} className="zs-rsd" onKeyDown={onKey}>
      <div className="zs-rsd-bd">
        <aside className="zs-rsd-side">
          <div className="zs-rsd-side-tb">
            <button type="button" className="zs-rsd-ib" onClick={add} title="Add configuration"><Icon name="plus" size="md"/></button>
            <button type="button" className="zs-rsd-ib" onClick={del} disabled={!cur} title="Remove"><Icon name="minus" size="md"/></button>
            <button type="button" className="zs-rsd-ib" onClick={dup} disabled={!cur} title="Duplicate"><Icon name="copy" size="md"/></button>
            <span className="zs-rsd-tb-sep"></span>
            <button type="button" className="zs-rsd-ib" onClick={() => move(-1)} disabled={idx <= 0} title="Move up"><Icon name="chevron-up" size="md"/></button>
            <button type="button" className="zs-rsd-ib" onClick={() => move(1)} disabled={idx < 0 || idx >= configs.length - 1} title="Move down"><Icon name="chevron-down" size="md"/></button>
          </div>
          <div className="zs-rsd-list">
            <div className="zs-rsd-sec">Built-in</div>
            {builtins.map((b) => (
              <button key={b.id} type="button" className={"zs-rsd-item is-b" + (b.id === selected ? " is-on" : "")} onClick={() => onSelect && onSelect(b.id)}>
                <span className="zs-rsd-nmrow"><code>{b.cmd}</code>{tag(b.id)}</span>
              </button>
            ))}
            <div className="zs-rsd-sec">Custom</div>
            {configs.map((c) => (
              <button key={c.id} type="button" className={"zs-rsd-item" + (c.id === selected ? " is-on" : "")} onClick={() => onSelect && onSelect(c.id)}>
                <span className="zs-rsd-nmrow"><span className="zs-rsd-nm">{c.name || "Unnamed"}</span>{tag(c.id)}</span>
                <code>{zsExprOf(c)}</code>
              </button>
            ))}
            {!configs.length && <button type="button" className="zs-rsd-empty" onClick={add}><Icon name="plus" size="sm"/>Add configuration</button>}
          </div>
        </aside>
        {cur ? (
          <main className="zs-rsd-main">
            <div className="zs-rsd-field">
              <label htmlFor="zs-rsd-name">Name</label>
              <input id="zs-rsd-name" className="zs-rsd-in" value={cur.name} onChange={(e) => { const v = e.target.value; upd((c) => { c.name = v; return c; }); }}/>
            </div>
            {homeUI}
            <div className="zs-rsd-block">
              <div className="zs-rsd-block-hd">
                <span className="zs-rsd-lbl">Filters</span>
                {(cur.rules || []).length > 1 && (
                  <Segmented label="Combine" value={cur.op === "|" ? "|" : "&"} onChange={(v) => upd((c) => { c.op = v; return c; })}
                    options={[{ value: "&", label: <>Match all <code>&amp;</code></> }, { value: "|", label: <>Match any <code>|</code></> }]}/>
                )}
              </div>
              <div className="zs-rsd-rules">
                {(cur.rules || []).map((r, i) => (
                  <div key={i} className="zs-rsd-rule">
                    <button type="button" className={"zs-rsd-not" + (r.not ? " is-on" : "")} onClick={() => updRule(i, { not: !r.not })} title={r.not ? "Negated (~) — click to include" : "Click to exclude matches (~)"}>{r.not ? "~ not" : "is"}</button>
                    <Select mono label="Function" value={r.fn} onChange={(v) => updRule(i, { fn: v })} title={ZS_RSD_HINT[r.fn]}
                      options={ZS_RSD_FNS.map((f) => ({ value: f, label: f + "()", text: f }))}/>
                    {r.fn === "mine" ? (
                      <span className="zs-rsd-mine">authored by <b>{me}</b> <span className="zs-rsd-dim">· user.email</span></span>
                    ) : (
                      <>
                        <Select label="Match" value={r.mode} onChange={(v) => updRule(i, { mode: v })}
                          options={(r.fn === "files" ? ZS_RSD_FILE : ZS_RSD_TEXT).map(([v, l]) => ({ value: v, label: l }))}/>
                        <div className="zs-rsd-val">
                          <input className="zs-rsd-in is-mono" value={r.value || ""} spellCheck="false" onChange={(e) => updRule(i, { value: e.target.value })}
                            placeholder={r.fn === "files" ? (r.mode === "glob" ? "lib/**/*.dart" : "app/lib/main.dart") : ZS_RSD_HINT[r.fn]}/>
                          {r.fn !== "files" && <button type="button" className={"zs-rsd-ci" + (r.ci ? " is-on" : "")} onClick={() => updRule(i, { ci: !r.ci })} title="Case-insensitive (-i)">Aa</button>}
                        </div>
                      </>
                    )}
                    <button type="button" className="zs-rsd-ib" onClick={() => upd((c) => { c.rules.splice(i, 1); return c; })} title="Remove filter"><Icon name="close" size="xs"/></button>
                  </div>
                ))}
                {!(cur.rules || []).length && <div className="zs-rsd-none">No filters — shows every commit (<code>all()</code>).</div>}
              </div>
              <div className="zs-rsd-add">
                {ZS_RSD_FNS.map((f) => <button key={f} type="button" className="zs-rsd-chip" onClick={() => upd((c) => { c.rules = [...(c.rules || []), zsNewRule(f)]; return c; })} title={ZS_RSD_HINT[f]}><Icon name="plus" size="xs"/>{f}</button>)}
              </div>
            </div>
            {preview}
          </main>
        ) : curB ? (
          <main className="zs-rsd-main">
            <div className="zs-rsd-field">
              <label>Name</label>
              <div className="zs-rsd-fixed"><code>{curB.cmd}</code><span className="zs-rsd-dim">Built-in · {curB.desc}</span></div>
            </div>
            {homeUI}
            {preview}
          </main>
        ) : (
          <main className="zs-rsd-main is-empty">
            <p>No custom configurations yet.</p>
            <button type="button" className="zs-rsd-btn" onClick={add}><Icon name="plus" size="sm"/>Add configuration</button>
          </main>
        )}
      </div>
      <div className="zs-rsd-ft">
        <a className="zs-rsd-doc" href={docHref} target="_blank" rel="noreferrer">Revset reference ↗</a>
        <span className="zs-rsd-grow"></span>
        <button type="button" className="zs-rsd-btn" onClick={cancel}>Cancel</button>
        <button type="button" className="zs-rsd-btn" onClick={onApply} disabled={!dirty}>Apply</button>
        <button type="button" className="zs-rsd-btn is-primary" onClick={onOk}>OK</button>
      </div>
      {ask && <ConfirmDialog title="Discard changes?" confirmLabel="Discard changes" onConfirm={discard} onCancel={() => setAsk(false)}>Your edits to the configurations haven’t been applied. Cancel keeps them here.</ConfirmDialog>}
    </div>
  );
  return (
    <Window title="jj log Configurations" active={active} buttons={{ close: true, zoom: true }} onClose={cancel} onZoom={onZoom} width={width} height={height}
      className={("zs-rsd-win " + className).trim()} style={style}>{box}</Window>
  );
}
RevsetDialog.builtins = [
  { id: "default", cmd: "jj log", desc: "Default revset — your mutable changes plus trunk context" },
  { id: "all", cmd: "jj log -r 'all()'", desc: "Every visible commit, incl. immutable history and untracked remotes" },
];
RevsetDialog.exprOf = zsExprOf;
RevsetDialog.ruleExpr = zsRuleExpr;
