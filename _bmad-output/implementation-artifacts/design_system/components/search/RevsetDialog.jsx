import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Switch } from "../forms/Switch.jsx";
import { Segmented } from "../forms/Segmented.jsx";

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
export function RevsetDialog({ builtins = RevsetDialog.builtins, configs = [], selected, defaultId = "default", me = "you", matchCount, total, dirty = false,
  overlay = false, docHref = "https://docs.jj-vcs.dev/latest/revsets/", onSelect, onDefaultChange, onChange, onCancel, onApply, onOk, onClose, className = "", style }) {
  const [copied, setCopied] = React.useState(false);
  const cur = configs.find((c) => c.id === selected) || null;
  const curB = !cur ? builtins.find((b) => b.id === selected) || null : null;
  const home = defaultId === "default" || defaultId === "all" || configs.some((c) => c.id === defaultId) ? defaultId : "default";
  const isHome = selected === home, lockHome = isHome && selected === "default";
  React.useEffect(() => {
    if (!overlay || !onClose) return undefined;
    const h = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, [overlay, onClose]);
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
  const copy = () => { if (!cmd) return; try { navigator.clipboard.writeText(cmd); } catch (e) { /* clipboard unavailable */ } setCopied(true); setTimeout(() => setCopied(false), 1200); };
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
          <span>{matchCount != null && <><b>{matchCount}</b>{total != null ? " of " + total : ""} changes match</>}</span>
          <button type="button" className="zs-rsd-link" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
        </div>
      </div>
    </div>
  );
  const box = (
    <div className={("zs-rsd " + className).trim()} role="dialog" aria-modal={overlay || undefined} aria-label="jj log configurations" style={style}>
      <div className="zs-rsd-hd">
        <span className="zs-rsd-title">jj log Configurations</span>
        <button type="button" className="zs-rsd-x" onClick={onClose} aria-label="Close"><Icon name="close" size={11}/></button>
      </div>
      <div className="zs-rsd-bd">
        <aside className="zs-rsd-side">
          <div className="zs-rsd-side-tb">
            <button type="button" className="zs-rsd-ib" onClick={add} title="Add configuration"><Icon name="plus" size={13}/></button>
            <button type="button" className="zs-rsd-ib" onClick={del} disabled={!cur} title="Remove"><Icon name="minus" size={13}/></button>
            <button type="button" className="zs-rsd-ib" onClick={dup} disabled={!cur} title="Duplicate"><Icon name="copy" size={13}/></button>
            <span className="zs-rsd-tb-sep"></span>
            <button type="button" className="zs-rsd-ib" onClick={() => move(-1)} disabled={idx <= 0} title="Move up"><Icon name="chevron-up" size={13}/></button>
            <button type="button" className="zs-rsd-ib" onClick={() => move(1)} disabled={idx < 0 || idx >= configs.length - 1} title="Move down"><Icon name="chevron-down" size={13}/></button>
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
            {!configs.length && <button type="button" className="zs-rsd-empty" onClick={add}><Icon name="plus" size={12}/>Add configuration</button>}
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
                    <select className="zs-rsd-sel is-mono" value={r.fn} onChange={(e) => updRule(i, { fn: e.target.value })} title={ZS_RSD_HINT[r.fn]}>
                      {ZS_RSD_FNS.map((f) => <option key={f} value={f}>{f}()</option>)}
                    </select>
                    {r.fn === "mine" ? (
                      <span className="zs-rsd-mine">authored by <b>{me}</b> <span className="zs-rsd-dim">· user.email</span></span>
                    ) : (
                      <>
                        <select className="zs-rsd-sel" value={r.mode} onChange={(e) => updRule(i, { mode: e.target.value })}>
                          {(r.fn === "files" ? ZS_RSD_FILE : ZS_RSD_TEXT).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                        </select>
                        <div className="zs-rsd-val">
                          <input className="zs-rsd-in is-mono" value={r.value || ""} spellCheck="false" onChange={(e) => updRule(i, { value: e.target.value })}
                            placeholder={r.fn === "files" ? (r.mode === "glob" ? "lib/**/*.dart" : "app/lib/main.dart") : ZS_RSD_HINT[r.fn]}/>
                          {r.fn !== "files" && <button type="button" className={"zs-rsd-ci" + (r.ci ? " is-on" : "")} onClick={() => updRule(i, { ci: !r.ci })} title="Case-insensitive (-i)">Aa</button>}
                        </div>
                      </>
                    )}
                    <button type="button" className="zs-rsd-ib" onClick={() => upd((c) => { c.rules.splice(i, 1); return c; })} title="Remove filter"><Icon name="close" size={10}/></button>
                  </div>
                ))}
                {!(cur.rules || []).length && <div className="zs-rsd-none">No filters — shows every commit (<code>all()</code>).</div>}
              </div>
              <div className="zs-rsd-add">
                {ZS_RSD_FNS.map((f) => <button key={f} type="button" className="zs-rsd-chip" onClick={() => upd((c) => { c.rules = [...(c.rules || []), zsNewRule(f)]; return c; })} title={ZS_RSD_HINT[f]}><Icon name="plus" size={10}/>{f}</button>)}
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
            <button type="button" className="zs-rsd-btn" onClick={add}><Icon name="plus" size={12}/>Add configuration</button>
          </main>
        )}
      </div>
      <div className="zs-rsd-ft">
        <a className="zs-rsd-doc" href={docHref} target="_blank" rel="noreferrer">Revset reference ↗</a>
        <span className="zs-rsd-grow"></span>
        <button type="button" className="zs-rsd-btn" onClick={onCancel || onClose}>Cancel</button>
        <button type="button" className="zs-rsd-btn" onClick={onApply} disabled={!dirty}>Apply</button>
        <button type="button" className="zs-rsd-btn is-primary" onClick={onOk}>OK</button>
      </div>
    </div>
  );
  if (!overlay) return box;
  return <div className="zs-rsd-ov" onPointerDown={(e) => { if (e.target === e.currentTarget && onClose) onClose(); }}>{box}</div>;
}
RevsetDialog.builtins = [
  { id: "default", cmd: "jj log", desc: "Default revset — your mutable changes plus trunk context" },
  { id: "all", cmd: "jj log -r 'all()'", desc: "Every visible commit, incl. immutable history and untracked remotes" },
];
RevsetDialog.exprOf = zsExprOf;
RevsetDialog.ruleExpr = zsRuleExpr;
