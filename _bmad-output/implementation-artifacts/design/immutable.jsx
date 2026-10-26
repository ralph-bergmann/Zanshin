/* global React */
// IMMUTABLE COMMITS — revset-aliases."immutable_heads()" (jj docs › Config › Set of immutable commits): the store, a mock evaluation
// over the demo history, and the page in Settings › Project. The heads and all their ancestors can't be rewritten; root() always.
// jj's default builtin_immutable_heads() = trunk() | tags() | untracked_remote_bookmarks() | untracked_remote_tags().
// The graph re-evaluates every change's `immutable` (+ `immWhy`, the reason) from this store (graph-view.jsx › applyImmutable).
(() => {
const { useState, useEffect, useMemo } = React;
const Ic = (p) => <window.Icon {...p}/>;
const EMBED = new URLSearchParams(location.search).has("embed");
const KEY = "zanshin.immutable";
const ME = (window.RevsetStore && window.RevsetStore.ME) || "Ralph Stein";
const PARTS = { trunk: true, tags: true, remoteBookmarks: true, remoteTags: true, others: false, bookmarks: [], custom: "" };
const DEFAULT = { trunkName: "main", ...PARTS };
const BUILT = [["trunk", "trunk()", "trunk"], ["tags", "tags()", "tags"], ["remoteBookmarks", "untracked_remote_bookmarks()", "untracked remote bookmarks"], ["remoteTags", "untracked_remote_tags()", "untracked remote tags"]];

let cfg = { ...DEFAULT };
if (!EMBED) try { const s = localStorage.getItem(KEY); if (s) cfg = { ...DEFAULT, ...JSON.parse(s) }; } catch {}
const subs = new Set();
const getImmutable = () => cfg;
const setImmutable = (patch) => { cfg = { ...cfg, ...patch }; if (!EMBED) try { localStorage.setItem(KEY, JSON.stringify(cfg)); } catch {} subs.forEach(f => f()); };
function useImmutable() {
  const [, force] = useState(0);
  useEffect(() => { const f = () => force(x => x + 1); subs.add(f); return () => subs.delete(f); }, []);
  return cfg;
}

// ---------- revset text ----------
const sym = (n) => /^[\w./@+-]+$/.test(n) ? n : '"' + n.replace(/"/g, '\\"') + '"';
function immutableExpr(c = cfg) {
  const on = BUILT.filter(([k]) => c[k]), parts = on.length === BUILT.length ? ["builtin_immutable_heads()"] : on.map(b => b[1]);
  c.bookmarks.forEach(b => parts.push(sym(b)));
  if (c.others) parts.push("(trunk().. & ~mine())");
  const cu = c.custom.trim();
  if (cu) parts.push(/[\s|&~]/.test(cu) && !/^\(.*\)$/.test(cu) ? "(" + cu + ")" : cu);
  return parts.length ? parts.join(" | ") : "none()";
}
const isDefault = (c = cfg) => immutableExpr(c) === "builtin_immutable_heads()";
function immutableSummary(c = cfg) {
  const on = BUILT.filter(([k]) => c[k]);
  const list = [...(on.length === BUILT.length ? ["jj’s default (trunk, tags, remote bookmarks you don’t track)"] : on.map(b => b[2])),
    ...(c.others ? ["other people’s changes"] : []), ...c.bookmarks, ...(c.custom.trim() ? ["a custom revset"] : [])];
  if (!list.length) return "Only root()";
  const s = list.join(", ");
  return /^jj/.test(s) ? s : s[0].toUpperCase() + s.slice(1);
}

// ---------- mock evaluation ----------
function ancestorsOf(M, id) {
  const out = new Set(), st = [...((M.get(id) || {}).parents || [])];
  while (st.length) { const x = st.pop(); if (out.has(x)) continue; out.add(x); const c = M.get(x); if (c) st.push(...c.parents); }
  return out;
}
// the custom part: bookmark / tag names, change ids, author(), description(), mine() are previewed; jj evaluates the rest
function customHeads(all, text) {
  const list = [], unknown = [];
  const val = (s) => s.replace(/^(substring|exact|glob):/, "").replace(/^["']|["']$/g, "");
  String(text || "").split("|").map(s => s.trim().replace(/^\((.*)\)$/, "$1").trim()).filter(Boolean).forEach(t => {
    let m, hit = null;
    if ((m = t.match(/^(author|description)\((.*)\)$/))) {
      const raw = m[2].trim(), v = val(raw).toLowerCase(), glob = /^glob:/.test(raw);
      const re = glob && new RegExp("^" + v.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$", "s");
      const test = (s) => { s = (s || "").toLowerCase(); return re ? re.test(s) : s.includes(v); };
      hit = all.filter(x => !x.isRoot && test(m[1] === "author" ? x.author : x.subject + (x.description ? "\n" + x.description : "")));
    } else if (t === "mine()") hit = all.filter(x => x.author === ME);
    else {
      const n = val(t), named = all.filter(x => (x.bookmarks || []).some(b => b.name === n) || (x.tags || []).includes(n));
      if (named.length) hit = named;
      else if (/^[k-z]{3,}$/.test(n)) { const p = all.filter(x => x.id.startsWith(n)); if (p.length === 1) hit = p; }
    }
    if (hit) list.push(...hit); else unknown.push(t);
  });
  return { list, unknown };
}
// why: change id → reason (a head names itself, its ancestors say "below …"; the first term wins) · names: the heads, for the summary
function evaluateImmutable(all, c = cfg) {
  const M = new Map(all.map(x => [x.id, x])), heads = [], names = [];
  const bm = (x) => x.bookmarks || [];
  const head = (x, at, below, name) => { heads.push({ id: x.id, at, below }); if (name && !names.includes(name)) names.push(name); };
  const trunkC = all.find(x => bm(x).some(b => b.name === c.trunkName));
  if (c.trunk && trunkC) head(trunkC, "trunk() · " + c.trunkName, "below trunk() · " + c.trunkName, c.trunkName);
  if (c.tags) all.forEach(x => (x.tags || []).forEach(t => head(x, "tag " + t, "below tag " + t, t)));
  if (c.remoteBookmarks) all.forEach(x => bm(x).forEach(b => { if (b.state === "remote") head(x, b.name + ", not tracked", "below " + b.name + ", not tracked", b.name); }));
  c.bookmarks.forEach(n => all.forEach(x => { if (bm(x).some(b => b.name === n)) head(x, n, "below " + n, n); }));
  let others = 0;
  if (c.others) {
    const inTrunk = trunkC ? new Set([trunkC.id, ...ancestorsOf(M, trunkC.id)]) : new Set();
    all.forEach(x => { if (!x.isRoot && x.author && x.author !== ME && !inTrunk.has(x.id)) { others++; head(x, "by " + x.author + ", not you", "below a change by " + x.author); } });
  }
  const cu = customHeads(all, c.custom);
  cu.list.forEach(x => head(x, "your custom revset", "below your custom revset"));
  if (cu.list.length) names.push("custom revset");
  if (others) names.push(others + (others === 1 ? " change" : " changes") + " by others");
  const why = new Map(), root = all.find(x => x.isRoot);
  if (root) why.set(root.id, "root() is always immutable");
  heads.forEach(h => { if (!why.has(h.id)) why.set(h.id, h.at); });
  heads.forEach(h => ancestorsOf(M, h.id).forEach(a => { if (!why.has(a)) why.set(a, h.below); }));
  return { why, names, unknown: cu.unknown };
}
const immutableCount = (all, c = cfg) => evaluateImmutable(all, c).why.size - (all.some(x => x.isRoot) ? 1 : 0);
// the commit list with `immutable` / `immWhy` per the config — the same array when nothing changes
function applyImmutable(all, c = cfg) {
  const { why } = evaluateImmutable(all, c);
  let changed = false;
  const next = all.map(x => {
    const imm = why.has(x.id), w = why.get(x.id);
    if (!!x.immutable === imm && x.immWhy === w) return x;
    changed = true;
    return { ...x, immutable: imm, immWhy: w };
  });
  return changed ? next : all;
}

// ---------- the page (Settings › Project › Immutable commits) ----------
const tomlStr = (s) => s.includes('"') ? "'" + s + "'" : '"' + s + '"';
function ImmutablePage({ project, onBack }) {
  const c = useImmutable(), K = window.SettingsKit;
  const all = window.GRAPH_COMMITS || [];
  const ev = useMemo(() => evaluateImmutable(all, c), [c, all]);
  const n = ev.why.size - (all.some(x => x.isRoot) ? 1 : 0);
  const bms = (x) => x.bookmarks || [];
  const tags = all.flatMap(x => x.tags || []), remote = all.flatMap(x => bms(x).filter(b => b.state === "remote").map(b => b.name));
  const pick = [...new Set(all.flatMap(x => bms(x).map(b => b.name)))].filter(b => b !== c.trunkName && !c.bookmarks.includes(b)).sort();
  const list = (a) => a.length ? a.join(", ") : "none here";
  const sw = (k, label) => <K.Switch on={!!c[k]} set={v => setImmutable({ [k]: v })} label={label}/>;
  return <>
    <div className="gimp-top"><button className="gimp-back" onClick={onBack}><Ic name="chevronRight" size={12}/>{project ? project.name : "Project"}</button></div>
    <div className="gimp-intro">
      <h2>Immutable commits</h2>
      <p>jj won’t rewrite these changes or anything below them: no edit, describe, squash, rebase or abandon. New change on top and Revert still work. In the graph they’re hatched.</p>
    </div>
    <section className="gset-grp"><h3>Built in<code>builtin_immutable_heads()</code></h3><div className="gset-box">
      <K.Row label="Trunk" hint={"Your main line. trunk() is " + c.trunkName + ", set under History."} cfg="trunk()">{sw("trunk", "Trunk")}</K.Row>
      <K.Row label="Tags" hint={"Released versions: " + list(tags) + "."} cfg="tags()">{sw("tags", "Tags")}</K.Row>
      <K.Row label="Remote bookmarks you don’t track" hint={"Fetched, but not yours to rewrite: " + list(remote) + "."} cfg="untracked_remote_bookmarks()">{sw("remoteBookmarks", "Remote bookmarks you don’t track")}</K.Row>
      <K.Row label="Remote tags you don’t track" hint="None in this repository." cfg="untracked_remote_tags()">{sw("remoteTags", "Remote tags you don’t track")}</K.Row>
    </div></section>
    <section className="gset-grp"><h3>Also immutable</h3><div className="gset-box">
      <K.Row label="Other people’s changes" hint="Everything after trunk() that isn’t yours. What’s below them is locked too, your own changes included." cfg="trunk().. & ~mine()">{sw("others", "Other people’s changes")}</K.Row>
      <K.Row label="Bookmarks" hint="A release or shared branch you never rewrite." stack>
        <div className="gimp-chips">
          {c.bookmarks.map(b => <span key={b} className="gimp-chip">{b}<button onClick={() => setImmutable({ bookmarks: c.bookmarks.filter(x => x !== b) })} aria-label={"Remove " + b} title="Remove"><Ic name="close" size={9}/></button></span>)}
          <select className="gset-sel gimp-add" value="" onChange={e => e.target.value && setImmutable({ bookmarks: [...c.bookmarks, e.target.value] })} aria-label="Add bookmark">
            <option value="">Add bookmark…</option>
            {pick.map(b => <option key={b} value={b}>{b}</option>)}
          </select>
        </div>
      </K.Row>
      <K.Row label="Custom revset" hint="Joined with |. The graph previews bookmark names, change ids, author() and description(); jj evaluates the rest." stack>
        <div className="gimp-col">
          <input className="gset-in is-code" value={c.custom} onChange={e => setImmutable({ custom: e.target.value })} placeholder={'description(glob:"hotfix:*")'} spellCheck={false} aria-label="Custom revset"/>
          {ev.unknown.length > 0 && <span className="gimp-unk">Not previewed here: <code>{ev.unknown.join(" | ")}</code></span>}
        </div>
      </K.Row>
    </div></section>
    <section className="gset-grp"><h3>Result</h3>
      <div className="gimp-out">
        <pre className="gimp-toml">{"[revset-aliases]\n"}{c.trunkName !== "main" ? '"trunk()" = ' + tomlStr(c.trunkName) + "\n" : ""}<b>{'"immutable_heads()"'}</b>{" = " + tomlStr(immutableExpr(c))}</pre>
        <div className="gimp-sum">
          <span><span className="ghatch"></span> <b>{n}</b> {n === 1 ? "change is" : "changes are"} immutable</span>
          {ev.names.length > 0 && <span className="gimp-heads">{ev.names.join(" · ")}</span>}
        </div>
      </div>
      <div className="gimp-note">
        <span>root() is always immutable. To rewrite one anyway, jj needs <code>--ignore-immutable</code>.</span>
        {!isDefault(c) && <button className="gimp-reset" onClick={() => setImmutable(PARTS)}>Reset to jj’s default</button>}
      </div>
    </section>
  </>;
}

Object.assign(window, { useImmutable, getImmutable, setImmutable, immutableExpr, immutableSummary, immutableCount, evaluateImmutable, applyImmutable, ImmutablePage });
})();
