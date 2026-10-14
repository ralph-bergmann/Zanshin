/* global React */
// Search study fork of revset-config.jsx (loaded by "Search Study.html"; the client keeps the original).
// Changes: own storage key · configs may carry a base variant (cfg.base) · free searches as revset ids "q:{…}" · store + dialog exported for graph-search.jsx.
(() => {
const { useState, useEffect, useRef, useMemo } = React;
const Ic = (p) => <window.Icon {...p}/>;

const BUILTIN = [
  { id: "default", cmd: "jj log", desc: "Default revset — your mutable changes plus trunk context" },
  { id: "all", cmd: "jj log -r 'all()'", desc: "Every visible commit, incl. immutable history and untracked remotes" },
];
const FNS = ["author", "committer", "mine", "subject", "description", "files"];
const FN_HINT = {
  author: "Author name or email", committer: "Committer name or email", mine: "Changes authored by your user.email",
  subject: "First line of the description", description: "Full description text", files: "Changes touching these paths",
};
const TEXT_MODES = [["substring", "contains"], ["exact", "is exactly"], ["glob", "matches glob"], ["regex", "matches regex"]];
const FILE_MODES = [["prefix", "path or folder"], ["file", "exact file"], ["glob", "glob"]];
const ME = "Ralph Stein";

// ---------- store ----------
// own key, so filters saved in the study never reach the client; the first run starts from the client's list
const KEY = "zanshin.study.revsetConfigs", CLIENT_KEY = "zanshin.graph.revsetConfigs", EMBED = new URLSearchParams(location.search).has("embed");
const SEED = [
  { id: "c-onb", name: "Onboarding feature", op: "&", rules: [{ fn: "files", mode: "prefix", value: "lib/features/onboarding/", not: false }] },
  { id: "c-lena", name: "Lena's changes", op: "&", rules: [{ fn: "author", mode: "substring", ci: true, value: "Lena", not: false }] },
  { id: "c-fix", name: "My fixes", op: "&", rules: [{ fn: "mine", not: false }, { fn: "subject", mode: "glob", value: "fix*", not: false }] },
];
let configs = SEED, ver = 0;
if (!EMBED) try { const s = localStorage.getItem(KEY) || localStorage.getItem(CLIENT_KEY); if (s) configs = JSON.parse(s); } catch {}
const subs = new Set();
const setConfigs = (next) => { configs = next; ver++; if (!EMBED) try { localStorage.setItem(KEY, JSON.stringify(next)); } catch {} subs.forEach(f => f()); };
function useStore() {
  const [, force] = useState(0);
  useEffect(() => { const f = () => force(x => x + 1); subs.add(f); return () => subs.delete(f); }, []);
  return configs;
}
const useRevsetVersion = () => { useStore(); return ver; };
// the default search (one-menu model): "default", "all" or a configuration id — listed first in the menu, ✕ returns to it
const HKEY = "zanshin.study.revsetDefault";
let home = "default";
if (!EMBED) try { const h = localStorage.getItem(HKEY); if (h) home = h; } catch {}
const validHome = (id, list = configs) => id === "default" || id === "all" || list.some(c => c.id === id) ? id : "default";
const getHome = () => validHome(home);
const setHome = (id) => { home = validHome(id); ver++; if (!EMBED) try { localStorage.setItem(HKEY, home); } catch {} subs.forEach(f => f()); };

// ---------- revset text ----------
const q = (v) => '"' + String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
function ruleExpr(r) {
  let e;
  if (r.fn === "mine") e = "mine()";
  else if (r.fn === "files") e = `files(${r.mode === "prefix" ? "" : r.mode + ":"}${q(r.value)})`;
  else e = `${r.fn}(${r.mode}${r.ci ? "-i" : ""}:${q(r.value)})`;
  return (r.not ? "~" : "") + e;
}
const validRules = (cfg) => cfg.rules.filter(r => r.fn === "mine" || String(r.value || "").trim());
// a config (or a free search) can narrow another variant: base & own rules
const DEFAULT_EXPR = "present(@) | ancestors(immutable_heads().., 2) | trunk()";
const wrap = (e) => / \| /.test(e) ? "(" + e + ")" : e;
function baseExpr(id, depth = 0) {
  if (!id || id === "all") return "all()";
  const cfg = id !== "default" && configs.find(x => x.id === id);
  return cfg && depth < 4 ? exprOf(cfg, depth + 1) : DEFAULT_EXPR;
}
function exprOf(cfg, depth = 0) {
  const rs = validRules(cfg);
  const own = rs.length ? rs.map(ruleExpr).join(cfg.op === "|" ? " | " : " & ") : "all()";
  if (!cfg.base || cfg.base === "all") return own;
  const b = baseExpr(cfg.base, depth);
  return rs.length ? wrap(b) + " & " + wrap(own) : b;
}
const cmdOf = (cfg) => `jj log -r '${exprOf(cfg)}'`;

// ---------- mock evaluation against graph data ----------
const esc = (s) => s.replace(/[.+^${}()|[\]\\]/g, "\\$&");
const globRe = (g, ci, path) => new RegExp("^" + esc(g).replace(/\*\*/g, "\u0000").replace(/\*/g, path ? "[^/]*" : ".*").replace(/\?/g, ".").replace(/\u0000/g, ".*") + "$", ci ? "is" : "s");
function textMatch(r, s) {
  s = s || ""; const v = r.value;
  if (r.mode === "regex") { try { return new RegExp(v, r.ci ? "i" : "").test(s); } catch { return false; } }
  if (r.mode === "glob") return globRe(v, r.ci).test(s);
  const a = r.ci ? s.toLowerCase() : s, b = r.ci ? v.toLowerCase() : v;
  return r.mode === "exact" ? a === b : a.includes(b);
}
function ruleMatch(r, c) {
  if (c.isRoot) return false;
  let hit;
  switch (r.fn) {
    case "mine": hit = c.author === ME; break;
    case "author": hit = textMatch(r, c.author); break;
    case "committer": hit = textMatch(r, c.committer || c.author); break;
    case "subject": hit = textMatch(r, c.subject); break;
    case "description": hit = textMatch(r, c.subject + (c.description ? "\n\n" + c.description : "")); break;
    case "files": {
      const v = r.value.replace(/^\.\//, "");
      hit = (c.files || []).some(({ path: p }) => r.mode === "glob" ? globRe(v, false, true).test(p) : r.mode === "file" ? p === v : p === v.replace(/\/$/, "") || p.startsWith(v.replace(/\/$/, "") + "/"));
      break;
    }
    default: hit = true;
  }
  return r.not ? !hit : hit;
}
function cfgMatch(cfg, depth = 0) {
  const rs = validRules(cfg);
  const own = !rs.length ? () => true : cfg.op === "|" ? (c) => rs.some(r => ruleMatch(r, c)) : (c) => rs.every(r => ruleMatch(r, c));
  if (!cfg.base || cfg.base === "all") return own;
  const base = baseMatch(cfg.base, depth + 1);
  return (c) => base(c) && own(c);
}
function baseMatch(id, depth = 0) {
  if (id === "all") return () => true;
  const cfg = id !== "default" && configs.find(x => x.id === id);
  return cfg && depth < 4 ? cfgMatch(cfg, depth) : (c) => c.inDefault;
}

// ---------- free searches ----------
// revset id "q:{json}" — { k: author | mine | files | description, m: mode, v: value, ci, b: the variant it came from, w: narrows b instead of replacing it }
const parseSearch = (id) => { if (typeof id !== "string" || id.slice(0, 2) !== "q:") return null; try { const s = JSON.parse(id.slice(2)); return s && s.k ? s : null; } catch { return null; } };
const encodeSearch = (s) => "q:" + JSON.stringify({ k: s.k, m: s.m, v: s.v, ci: s.ci || undefined, b: s.b, w: s.w || undefined });
const searchRule = (s) => s.k === "mine" ? { fn: "mine", not: false } : s.k === "files" ? { fn: "files", mode: s.m || "prefix", value: s.v, not: false } : { fn: s.k, mode: s.m || "substring", ci: !!s.ci, value: s.v, not: false };
const searchExpr = (s) => { const e = ruleExpr(searchRule(s)); return s.w && s.b && s.b !== "all" ? wrap(baseExpr(s.b)) + " & " + e : e; };
const searchCmd = (s) => `jj log -r '${searchExpr(s)}'`;
// cheap, data-free check for the "in …" menu: can a variant still match together with the search?
// author, committer, subject and description hold one value per change (files() does not), so two conditions on the same
// field only clash when one pins a value (exact, or mine() = your name) that the other can't match. Two patterns never clash.
const FIELD = { author: "author", mine: "author", committer: "committer", subject: "subject", description: "description" };
const asText = (r) => r.fn === "mine" ? { fn: "author", mode: "exact", value: ME, ci: false, not: r.not } : r;
const pinOf = (r) => r.not ? null : r.fn === "mine" ? ME : r.mode === "exact" ? r.value : null;
function clash(a, b) {
  if (!FIELD[a.fn] || FIELD[a.fn] !== FIELD[b.fn]) return false;
  const test = (v, other) => { const o = asText(other), hit = textMatch(o, v); return o.not ? hit : !hit; };
  const va = pinOf(a), vb = pinOf(b);
  return va != null ? test(va, b) : vb != null ? test(vb, a) : false;
}
function canRefine(s, id, depth = 0) {
  if (!id || id === "all" || id === "default" || depth > 3) return true;
  const cfg = configs.find(x => x.id === id);
  if (!cfg) return true;
  if (cfg.base && !canRefine(s, cfg.base, depth + 1)) return false;
  const rule = searchRule(s), rs = validRules(cfg);
  if (!rs.length) return true;
  return cfg.op === "|" ? rs.some(r => !clash(rule, r)) : rs.every(r => !clash(rule, r));
}
function revsetMatch(id) {
  const s = parseSearch(id);
  if (!s) return baseMatch(id);
  const r = searchRule(s), base = s.w && s.b ? baseMatch(s.b) : () => true;
  return (c) => base(c) && ruleMatch(r, c);
}

// ---------- configuration dialog ----------
let seq = 0;
const newId = () => "c-" + Date.now().toString(36) + (seq++);
const newRule = (fn) => fn === "mine" ? { fn, not: false } : fn === "files" ? { fn, mode: "prefix", value: "", not: false } : { fn, mode: "substring", ci: false, value: "", not: false };

// withHome (one-menu model): the built-ins are selectable and any entry can be made the default search
function RevsetDialog({ initial, onClose, onApply, withHome = false }) {
  const [draft, setDraft] = useState(() => JSON.parse(JSON.stringify(configs)));
  const [sel, setSel] = useState(() => initial || (configs[0] && configs[0].id) || null);
  const [homeD, setHomeD] = useState(() => getHome());
  const [copied, setCopied] = useState(false);
  const nameRef = useRef(null);
  const cur = draft.find(c => c.id === sel);
  const curB = withHome && !cur ? BUILTIN.find(b => b.id === sel) || null : null;
  const homeV = validHome(homeD, draft);
  const dirty = JSON.stringify(draft) !== JSON.stringify(configs) || (withHome && homeV !== getHome());
  useEffect(() => {
    const h = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, []);
  const upd = (fn) => setDraft(d => d.map(c => c.id === sel ? fn(JSON.parse(JSON.stringify(c))) : c));
  const updRule = (i, patch) => upd(c => { const r = { ...c.rules[i], ...patch }; if (patch.fn && patch.fn !== c.rules[i].fn) Object.assign(r, newRule(patch.fn), { value: patch.fn === "mine" ? undefined : c.rules[i].value || "", not: r.not }); c.rules[i] = r; return c; });
  const add = () => { const c = { id: newId(), name: "New configuration", op: "&", rules: [newRule("files")] }; setDraft(d => [...d, c]); setSel(c.id); setTimeout(() => nameRef.current && nameRef.current.select(), 0); };
  const dup = () => { if (!cur) return; const c = { ...JSON.parse(JSON.stringify(cur)), id: newId(), name: cur.name + " copy" }; setDraft(d => { const i = d.findIndex(x => x.id === sel); return [...d.slice(0, i + 1), c, ...d.slice(i + 1)]; }); setSel(c.id); };
  const del = () => { if (!cur) return; const i = draft.findIndex(x => x.id === sel); const rest = draft.filter(x => x.id !== sel); setDraft(rest); setSel(rest.length ? rest[Math.min(i, rest.length - 1)].id : null); };
  const move = (dir) => setDraft(d => { const i = d.findIndex(x => x.id === sel), j = i + dir; if (i < 0 || j < 0 || j >= d.length) return d; const n = [...d]; [n[i], n[j]] = [n[j], n[i]]; return n; });
  const apply = () => { setConfigs(draft); if (withHome) setHome(homeV); };
  const ok = () => { apply(); onApply(cur ? cur.id : curB ? curB.id : null); onClose(); };
  const all = window.GRAPH_COMMITS || [];
  const count = useMemo(() => cur ? all.filter(cfgMatch(cur)).length : curB ? all.filter(baseMatch(curB.id)).length : 0, [cur, curB, all]);
  const cmdNow = cur ? cmdOf(cur) : curB ? curB.cmd : "";
  const copy = () => { if (!cmdNow) return; try { navigator.clipboard.writeText(cmdNow); } catch {} setCopied(true); setTimeout(() => setCopied(false), 1200); };
  const isHome = withHome && sel === homeV, lockHome = isHome && sel === "default";
  const tag = (id) => withHome && homeV === id && <span className="rsd-tag">Default</span>;
  const homeUI = withHome && (
    <label className="rsd-opt">
      <span className="rsd-opt-t"><span>Default search</span><span className="rsd-dim">{lockHome ? "Used whenever no other configuration is the default" : "Listed first in the search menu — ✕ in the search field returns to it"}</span></span>
      <button role="switch" aria-checked={isHome} disabled={lockHome} className={"gtb-switch " + (isHome ? "on" : "")} onClick={() => setHomeD(isHome ? "default" : sel)}></button>
    </label>
  );
  const idx = cur ? draft.indexOf(cur) : -1;

  return (
    <div className="rsd-ov" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="rsd" role="dialog" aria-modal="true" aria-label="jj log configurations">
        <div className="rsd-hd">
          <span className="rsd-title">jj log Configurations</span>
          <button className="rsd-x" onClick={onClose} aria-label="Close"><Ic name="close" size={11}/></button>
        </div>
        <div className="rsd-bd">
          <aside className="rsd-side">
            <div className="rsd-side-tb">
              <button className="rsd-ib" onClick={add} title="Add configuration"><Ic name="plus" size={13}/></button>
              <button className="rsd-ib" onClick={del} disabled={!cur} title="Remove"><svg width="13" height="13" viewBox="0 0 16 16"><path d="M3 8h10" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></svg></button>
              <button className="rsd-ib" onClick={dup} disabled={!cur} title="Duplicate"><svg width="13" height="13" viewBox="0 0 16 16"><g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5V3A1.5 1.5 0 0 0 9 1.5H4A1.5 1.5 0 0 0 2.5 3v5A1.5 1.5 0 0 0 4 9.5h.5"/></g></svg></button>
              <span className="rsd-tb-sep"/>
              <button className="rsd-ib" onClick={() => move(-1)} disabled={idx <= 0} title="Move up"><svg width="13" height="13" viewBox="0 0 16 16"><path d="M4.5 9.5L8 6l3.5 3.5" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/></svg></button>
              <button className="rsd-ib" onClick={() => move(1)} disabled={idx < 0 || idx >= draft.length - 1} title="Move down"><Ic name="chevronDown" size={13}/></button>
            </div>
            <div className="rsd-list">
              <div className="rsd-sec-l">Built-in</div>
              {BUILTIN.map(b => withHome
                ? <button key={b.id} className={"rsd-item is-b " + (b.id === sel ? "on" : "")} onClick={() => setSel(b.id)}><span className="rsd-nmrow"><code>{b.cmd}</code>{tag(b.id)}</span></button>
                : <div key={b.id} className="rsd-item is-fixed" title="Built-in — not editable"><code>{b.cmd}</code></div>)}
              <div className="rsd-sec-l">Custom</div>
              {draft.map(c => (
                <button key={c.id} className={"rsd-item " + (c.id === sel ? "on" : "")} onClick={() => setSel(c.id)}>
                  <span className="rsd-nmrow"><span className="nm">{c.name || "Unnamed"}</span>{tag(c.id)}</span>
                  <code>{exprOf(c)}</code>
                </button>
              ))}
              {!draft.length && <button className="rsd-empty" onClick={add}><Ic name="plus" size={12}/>Add configuration</button>}
            </div>
          </aside>
          {cur ? (
            <main className="rsd-main">
              <div className="rsd-field">
                <label htmlFor="rsd-name">Name</label>
                <input id="rsd-name" ref={nameRef} className="rsd-in" value={cur.name} onChange={(e) => upd(c => (c.name = e.target.value, c))}/>
              </div>
              {homeUI}
              <div className="rsd-block">
                <div className="rsd-block-hd">
                  <span className="rsd-lbl">Filters</span>
                  {cur.rules.length > 1 && (
                    <div className="gtb-seg rsd-seg" role="radiogroup" aria-label="Combine">
                      <button role="radio" aria-checked={cur.op !== "|"} className={cur.op !== "|" ? "on" : ""} onClick={() => upd(c => (c.op = "&", c))}>Match all <code>&amp;</code></button>
                      <button role="radio" aria-checked={cur.op === "|"} className={cur.op === "|" ? "on" : ""} onClick={() => upd(c => (c.op = "|", c))}>Match any <code>|</code></button>
                    </div>
                  )}
                </div>
                <div className="rsd-rules">
                  {cur.rules.map((r, i) => (
                    <div key={i} className="rsd-rule">
                      <button className={"rsd-not " + (r.not ? "on" : "")} onClick={() => updRule(i, { not: !r.not })} title={r.not ? "Negated (~) — click to include" : "Click to exclude matches (~)"}>{r.not ? "~ not" : "is"}</button>
                      <select className="rsd-sel mono" value={r.fn} onChange={(e) => updRule(i, { fn: e.target.value })} title={FN_HINT[r.fn]}>
                        {FNS.map(f => <option key={f} value={f}>{f}()</option>)}
                      </select>
                      {r.fn === "mine" ? (
                        <span className="rsd-mine">authored by <b>{ME}</b> <span className="rsd-dim">· user.email</span></span>
                      ) : <>
                        <select className="rsd-sel" value={r.mode} onChange={(e) => updRule(i, { mode: e.target.value })}>
                          {(r.fn === "files" ? FILE_MODES : TEXT_MODES).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                        </select>
                        <div className="rsd-val">
                          <input className="rsd-in mono" value={r.value} placeholder={r.fn === "files" ? (r.mode === "glob" ? "lib/**/*.dart" : "app/lib/main.dart") : FN_HINT[r.fn]} onChange={(e) => updRule(i, { value: e.target.value })} spellCheck="false"/>
                          {r.fn !== "files" && <button className={"rsd-ci " + (r.ci ? "on" : "")} onClick={() => updRule(i, { ci: !r.ci })} title="Case-insensitive (-i)">Aa</button>}
                        </div>
                      </>}
                      <button className="rsd-ib" onClick={() => upd(c => (c.rules.splice(i, 1), c))} title="Remove filter"><Ic name="close" size={10}/></button>
                    </div>
                  ))}
                  {!cur.rules.length && <div className="rsd-none">No filters — shows every commit (<code>all()</code>).</div>}
                </div>
                <div className="rsd-add">
                  {FNS.map(f => <button key={f} className="rsd-chip" onClick={() => upd(c => (c.rules.push(newRule(f)), c))} title={FN_HINT[f]}><Ic name="plus" size={10}/>{f}</button>)}
                </div>
              </div>
              <div className="rsd-block">
                <span className="rsd-lbl">Command</span>
                <div className="rsd-pv">
                  <div className="rsd-pv-cmd"><span className="gtb-prompt">❯ </span>{cmdOf(cur)}</div>
                  <div className="rsd-pv-ft">
                    <span><b>{count}</b> of {all.length} changes match</span>
                    <button className="rsd-link-btn" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
                  </div>
                </div>
              </div>
            </main>
          ) : curB ? (
            <main className="rsd-main">
              <div className="rsd-field">
                <label>Name</label>
                <div className="rsd-fixed"><code>{curB.cmd}</code><span className="rsd-dim">Built-in · {curB.desc}</span></div>
              </div>
              {homeUI}
              <div className="rsd-block">
                <span className="rsd-lbl">Command</span>
                <div className="rsd-pv">
                  <div className="rsd-pv-cmd"><span className="gtb-prompt">❯ </span>{curB.cmd}</div>
                  <div className="rsd-pv-ft">
                    <span><b>{count}</b> of {all.length} changes match</span>
                    <button className="rsd-link-btn" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
                  </div>
                </div>
              </div>
            </main>
          ) : (
            <main className="rsd-main rsd-main-empty">
              <p>No custom configurations yet.</p>
              <button className="rsd-btn" onClick={add}><Ic name="plus" size={12}/>Add configuration</button>
            </main>
          )}
        </div>
        <div className="rsd-ft">
          <a className="rsd-doc" href="https://docs.jj-vcs.dev/latest/revsets/" target="_blank" rel="noreferrer">Revset reference ↗</a>
          <span className="rsd-grow"/>
          <button className="rsd-btn" onClick={onClose}>Cancel</button>
          <button className="rsd-btn" onClick={apply} disabled={!dirty}>Apply</button>
          <button className="rsd-btn primary" onClick={ok}>OK</button>
        </div>
      </div>
    </div>
  );
}

window.RevsetStore = { BUILTIN, ME, DEFAULT_EXPR, useStore, getConfigs: () => configs, setConfigs, getHome, setHome, exprOf, cmdOf, ruleExpr, newId, parseSearch, encodeSearch, searchRule, searchExpr, searchCmd, canRefine };
Object.assign(window, { RevsetDialog, revsetMatch, useRevsetVersion });
})();
