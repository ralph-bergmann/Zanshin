/* global React */
// PUSH — "Push…" opens this sheet instead of pushing (design system › Push, round F). jj isn't branch-based: one push can move several
// bookmarks, backwards or sideways, or send nothing because no bookmark sits on @. The sheet is a surface for exactly the parameters of
// `jj git push` (jj v0.46.0) — nothing invented, no sequence of commands — on the 18px glass sheet of jj log Configurations.
// · Preselection = `jj git push` alone: tracked bookmarks in remote_bookmarks(remote=<remote>)..@ (revsets.git-push).
// · A ticked row adds --bookmark (an untracked one gets tracked); Tracked / All / Deleted = --tracked / --all / --deleted;
//   "Push @ as a new bookmark" = --change @ with the generated push-… name shown in advance, an edited name = --named <name>=@.
// · --remote for anything but the default (Settings › Project › Push to = git.push, else origin).
// · Each row shows its --dry-run kind (new · forward · backwards · sideways · delete — the last three warn) and what jj would refuse
//   (conflicts, no description, private) with Allow → --allow-conflicts / --allow-empty-description / --allow-private.
// · The footer shows the exact command. ↩ pushes, Esc and the scrim cancel (not while pushing).
(() => {
const { useState, useEffect, useRef } = React;
const KIND = { new: ["new", "new"], forward: ["forward", ""], backward: ["backwards", "warn"], sideways: ["sideways", "warn"], delete: ["delete", "warn"], none: ["up to date", "none"] };
const REFUSE = {
  "empty-description": ["has no description", "--allow-empty-description"],
  private: ["is private (git.private-commits)", "--allow-private"],
  conflicts: ["has conflicts", "--allow-conflicts"],
};
const ALLOW = { "empty-description": "emptyDescription", private: "private", conflicts: "conflicts" };
const blockedBy = (x, allow) => !!(x && x.refused && !allow[ALLOW[x.refused]]);
const pushable = (b, allow) => b.kind !== "none" && !blockedBy(b, allow);
const noDesc = (c) => !c.description && (!c.subject || c.subject === "(no description set)");
const ID = ({ id }) => <span className="gcid"><b>{id.slice(0, 2)}</b>{id.slice(2, 8)}</span>;
const CHECK = <svg width="10" height="10" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3 3 7-7" stroke="currentColor" strokeWidth="2.2" fill="none" strokeLinecap="round" strokeLinejoin="round"/></svg>;
const SPIN = <svg className="gpush-spin" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" strokeWidth="1.8" strokeOpacity=".25"/><path d="M8 2a6 6 0 0 1 6 6" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>;

// What a push could send, read from the repo. Bookmark state → the --dry-run kind: ahead → forward (the remote sits `ahead` first
// parents below), local → new (not tracked yet), behind → backwards, diverged → sideways; in sync and remote-only → nothing to send.
// The commits a bookmark would send are its ancestors the remote doesn't have yet; jj refuses the push if one has conflicts or no description.
function pushPlan(all, wcId) {
  const by = new Map(all.map(c => [c.id, c]));
  const anc = (id) => { const s = new Set(), st = [id]; while (st.length) { const x = st.pop(); if (s.has(x) || !by.has(x)) continue; s.add(x); by.get(x).parents.forEach(p => st.push(p)); } return s; };
  const down = (id, n) => { let x = id; for (let i = 0; i < n && x; i++) { const c = by.get(x); x = c && c.parents[0]; } return x || null; };
  const onRemote = new Set();
  all.forEach(c => {
    if (c.immutable) onRemote.add(c.id);
    c.bookmarks.forEach(b => { const at = b.state === "synced" || b.state === "remote" ? c.id : b.state === "ahead" ? down(c.id, b.ahead || 1) : null; if (at) anc(at).forEach(x => onRemote.add(x)); });
  });
  const refusal = (id) => {
    const send = [...anc(id)].filter(x => !onRemote.has(x)).map(x => by.get(x));
    const c = send.find(x => x.hasConflict) || send.find(noDesc);
    return c ? { refused: c.hasConflict ? "conflicts" : "empty-description", refusedAt: c.id } : {};
  };
  const toWc = anc(wcId), KINDS = { ahead: "forward", local: "new", behind: "backward", diverged: "sideways" };
  const rows = [];
  all.forEach(c => c.bookmarks.forEach(b => {
    const kind = KINDS[b.state]; if (!kind) return;
    const tracked = b.state !== "local";
    rows.push({ name: b.name, tracked, kind, from: b.state === "ahead" ? down(c.id, b.ahead || 1) : null, to: c.id, inDefault: tracked && toWc.has(c.id), ...refusal(c.id) });
  }));
  rows.sort((a, b) => b.inDefault - a.inDefault);
  return { rows, change: by.has(wcId) ? { id: wcId, generated: "push-" + wcId.slice(0, 8), on: false, name: null, ...refusal(wcId) } : null };
}

// the exact command for a dialog state — minimal: no flag for a default, a bulk flag only while the selection IS that bulk choice
function pushCommand({ rows, selected, bulk, remotes, defaultRemote, change, allow }) {
  const sel = new Set(selected), send = rows.filter(b => sel.has(b.name) && pushable(b, allow));
  const withChange = !!(change && change.on && !blockedBy(change, allow));
  if (!send.length && !withChange) return "";
  const p = ["jj git push"];
  remotes.filter(r => !(remotes.length === 1 && r === defaultRemote)).forEach(r => p.push("--remote " + r));
  const def = rows.filter(b => b.inDefault && pushable(b, allow)).map(b => b.name);
  const isDefault = def.length === send.length && def.every(n => sel.has(n));
  if (bulk && !withChange) p.push("--" + bulk);
  else if (!(isDefault && !withChange)) send.forEach(b => p.push("--bookmark " + b.name));
  if (withChange) { const nm = (change.name || "").trim(); p.push(change.name != null && nm && nm !== change.generated ? "--named " + nm + "=@" : "--change @"); }
  const why = new Set(send.map(b => b.refused).filter(Boolean));
  if (withChange && change.refused) why.add(change.refused);
  Object.keys(REFUSE).forEach(k => { if (why.has(k)) p.push(REFUSE[k][1]); });
  return p.join(" ");
}
const ERRORS = {
  network: (r) => "Couldn’t reach " + r + ". Check the connection, then try again.",
  auth: (r) => r + " refused the credentials. Check your SSH key or token, then try again.",
  stale: (r) => r + " has changed since the last fetch. Fetch first — then push.",
};

function PushDialog({ plan, remotes = ["origin"], defaultRemote = "origin", error: error0 = null, onDone, onCancel }) {
  const { rows } = plan;
  const [to, setTo] = useState([defaultRemote]);
  const [selected, setSelected] = useState(null);           // null = the preselection (what jj git push alone sends)
  const [bulk, setBulk] = useState(null);
  const [change, setChange] = useState(plan.change);
  const [allow, setAllow] = useState({});
  const [state, setState] = useState("ready");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState(error0);
  const box = useRef(null);
  const sel = new Set(selected != null ? selected : rows.filter(b => b.inDefault).map(b => b.name));
  const pushSet = rows.filter(b => sel.has(b.name) && pushable(b, allow));
  const chOn = !!(change && change.on && !blockedBy(change, allow));
  const cmd = pushCommand({ rows, selected: [...sel], bulk, remotes: to, defaultRemote, change, allow });
  const warnN = pushSet.filter(b => KIND[b.kind][1] === "warn").length;
  const empty = !pushSet.length && !chOn, busy = state === "pushing";
  const toggle = (name) => { const n = new Set(sel); n.has(name) ? n.delete(name) : n.add(name); setSelected([...n]); setBulk(null); };
  const pickBulk = (k) => {
    const pick = k === "all" ? rows.filter(b => b.kind !== "delete") : k === "tracked" ? rows.filter(b => b.tracked && b.kind !== "delete") : k === "deleted" ? rows.filter(b => b.kind === "delete") : rows.filter(b => b.inDefault);
    setSelected(k === "default" ? null : pick.map(b => b.name)); setBulk(k === "default" ? null : k);
  };
  const push = () => {
    if (empty || busy) return;
    setState("pushing"); setProgress(0);
    let k = 0;
    const iv = setInterval(() => {
      k += 1; setProgress(Math.min(1, k / 8));
      if (k >= 8) { clearInterval(iv); onDone({ names: pushSet.map(b => b.name), change: chOn ? { id: change.id, name: (change.name || "").trim() || change.generated } : null, remotes: to, cmd }); }
    }, 140);
  };
  // focus starts on Push, Tab stays inside, focus returns to whatever had it; Esc cancels (not while pushing)
  useEffect(() => {
    const el = box.current, prev = document.activeElement;
    const f = el.querySelector('[data-k="push"]:not(:disabled)') || el.querySelector("button:not(:disabled),input:not(:disabled)") || el;
    f.focus({ preventScroll: true });
    return () => { if (prev && prev.focus && document.contains(prev)) prev.focus({ preventScroll: true }); };
  }, []);
  const busyRef = useRef(false); busyRef.current = busy;
  useEffect(() => {
    const k = (e) => { if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); if (!busyRef.current) onCancel(); } };
    window.addEventListener("keydown", k, true); return () => window.removeEventListener("keydown", k, true);
  }, []);
  const onKey = (e) => {
    if (e.key === "Tab") {
      const f = [...box.current.querySelectorAll("button:not(:disabled),input:not(:disabled)")].filter(n => n.getClientRects().length);
      if (!f.length) return;
      if (e.shiftKey && document.activeElement === f[0]) { e.preventDefault(); f[f.length - 1].focus(); }
      else if (!e.shiftKey && document.activeElement === f[f.length - 1]) { e.preventDefault(); f[0].focus(); }
    } else if (e.key === "Enter" && !e.target.matches("input,textarea") && !(e.target.matches("button") && !e.target.matches('.gck,[data-k="push"]'))) { e.preventDefault(); push(); }
  };
  const ref = change && change.refused && REFUSE[change.refused], chBlocked = blockedBy(change, allow);
  const errRemote = (error && error.remote) || to[0];
  return (
    <div className="gpush-ov" onPointerDown={(e) => { if (e.target === e.currentTarget && !busy) onCancel(); }}>
      <div ref={box} className="gpush" role="dialog" aria-modal="true" aria-label="Push" onKeyDown={onKey}>
        <div className="gpush-hd">
          <h2 className="gpush-title">Push</h2>
          <div className="gpush-to" role="group" aria-label="To remote"><span>to</span>
            {remotes.map(r => (
              <button key={r} type="button" className={"gpush-chip is-mono" + (to.includes(r) ? " on" : "")} aria-pressed={to.includes(r)} title={"--remote " + r} disabled={busy}
                onClick={() => { const n = to.includes(r) ? to.filter(x => x !== r) : [...to, r]; if (n.length) setTo(n); }}>{r}</button>
            ))}
          </div>
        </div>
        <div className="gpush-bd">
          {error && (
            <div className="gpush-note is-error" role="alert">
              <window.Icon name="alert" size={14} className="gpush-note-ic"/>
              <span className="gpush-note-t">{ERRORS[error.kind](errRemote)}</span>
              {error.kind === "stale"
                ? <button className="rsd-btn gpush-nbtn" title={"jj git fetch --remote " + errRemote} onClick={() => setError(null)}><window.Icon name="fetch" size={12}/>Fetch</button>
                : <button className="rsd-btn gpush-nbtn" title={cmd || undefined} onClick={() => setError(null)}>Try again</button>}
            </div>
          )}
          <section className="gpush-sec" aria-label="Bookmarks">
            <div className="gpush-sec-hd"><span>Bookmarks</span>
              <span className="gpush-bulk">
                {[["default", "As jj git push", "remote_bookmarks(remote=" + to[0] + ")..@"], ["tracked", "Tracked", "--tracked"], ["all", "All", "--all"], ["deleted", "Deleted", "--deleted"]].map(([k, l, tt]) => (
                  <button key={k} type="button" className={"gpush-bk" + ((bulk || "default") === k && (k !== "default" || selected == null) ? " on" : "")} title={tt} disabled={busy} onClick={() => pickBulk(k)}>{l}</button>
                ))}
              </span>
            </div>
            {rows.length ? (
              <div className="gpush-list" role="group" aria-label="Bookmarks">
                {rows.map(b => {
                  const k = KIND[b.kind] || KIND.forward, rf = b.refused && REFUSE[b.refused], blocked = blockedBy(b, allow), on = sel.has(b.name) && !blocked;
                  return (
                    <div key={b.name} className={"gpush-row" + (on ? " is-sel" : "") + (blocked ? " is-refused" : "")} onClick={() => !blocked && !busy && toggle(b.name)}>
                      <button type="button" className={"gck" + (on ? " on" : "")} role="checkbox" aria-checked={on} aria-label={b.name} disabled={blocked || busy} onClick={(e) => { e.stopPropagation(); toggle(b.name); }}>{on && CHECK}</button>
                      <span className="gpush-what">
                        <span className="gpush-name">{b.name}</span>
                        {rf ? <span className="gpush-sub is-refused">{blocked ? "Refused — " : "Allowed — "}<ID id={b.refusedAt}/> {rf[0]}</span>
                          : !b.tracked && b.kind !== "delete" ? <span className="gpush-sub">not tracked yet — the push tracks it</span> : null}
                      </span>
                      <span className="gpush-move">{b.from ? <ID id={b.from}/> : <span className="gpush-none">—</span>}<span className="gpush-arrow">→</span>{b.to ? <ID id={b.to}/> : <span className="gpush-none">deleted</span>}</span>
                      {rf && blocked
                        ? <button type="button" className="gpush-chip" title={rf[1]} onClick={(e) => { e.stopPropagation(); setAllow({ ...allow, [ALLOW[b.refused]]: true }); }}>Allow</button>
                        : <span className={"gpush-kind" + (k[1] ? " is-" + k[1] : "")}>{k[1] === "warn" && <window.Icon name="conflict" size={11}/>}{k[0]}</span>}
                    </div>
                  );
                })}
              </div>
            ) : <div className="gpush-empty">No bookmark has anything to send to {to.join(", ")}.</div>}
          </section>
          {change && (
            <section className={"gpush-change" + (chOn ? " is-on" : "")} aria-label="Push a change">
              <button type="button" className={"gck" + (chOn ? " on" : "")} role="checkbox" aria-checked={chOn} aria-label="Push @ as a new bookmark" disabled={chBlocked || busy}
                onClick={() => setChange({ ...change, on: !change.on })}>{chOn && CHECK}</button>
              <div className="gpush-change-t">
                <div className="gpush-change-l"><span>Push <ID id={change.id}/> as a new bookmark</span>
                  {chBlocked && <button type="button" className="gpush-chip" title={ref[1]} onClick={() => setAllow({ ...allow, [ALLOW[change.refused]]: true })}>Allow</button>}</div>
                {ref && <span className="gpush-sub is-refused">{chBlocked ? "Refused — " : "Allowed — "}<ID id={change.refusedAt}/> {ref[0]}</span>}
                <input className="gpush-in" value={change.name != null ? change.name : change.generated} disabled={!chOn || busy} spellCheck="false" aria-label="Bookmark name"
                  onChange={(e) => setChange({ ...change, name: e.target.value })}/>
                <span className="gpush-sub">{change.name == null || change.name === change.generated
                  ? <>The name jj generates (<code>templates.git_push_bookmark</code>) — type your own to name it.</>
                  : <>Your name — pushed with <code>--named</code>.</>}</span>
              </div>
            </section>
          )}
          {!empty && warnN > 0 && (
            <div className="gpush-note" role="note"><window.Icon name="conflict" size={14} className="gpush-note-ic"/>
              <span className="gpush-note-t">{warnN === 1 ? "One bookmark" : warnN + " bookmarks"} will rewrite or remove history on {to.join(", ")} — moved backwards, sideways or deleted. The push stops if the remote has moved since you fetched.</span></div>
          )}
          {empty && !error && <div className="gpush-empty" role="status">Nothing to push. Choose a bookmark{change ? ", or push @ as a new one" : ""}.</div>}
        </div>
        <div className="gpush-ft">
          {busy
            ? <div className="gpush-run" role="status"><span className="gpush-prog"><span style={{ width: progress * 100 + "%" }}></span></span><span>Pushing {pushSet.length + (chOn ? 1 : 0)} to {to.join(", ")}…</span></div>
            : <code className="gpush-cmd" aria-label="Command">{cmd || "jj git push"}</code>}
          <div className="gpush-btns">
            <span className="gpush-hint">Checked with <code>--dry-run</code></span>
            <button className="rsd-btn" onClick={onCancel} disabled={busy}>Cancel</button>
            <button className="rsd-btn primary" data-k="push" aria-busy={busy || undefined} disabled={empty} onClick={push} title={cmd || undefined}>{busy && SPIN}Push</button>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { PushDialog, pushPlan, pushCommand });
})();
