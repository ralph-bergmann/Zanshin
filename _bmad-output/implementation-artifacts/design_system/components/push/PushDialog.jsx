import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Button } from "../actions/Button.jsx";
import { Checkbox } from "../forms/Checkbox.jsx";
import { Chip } from "../controls/Chip.jsx";
import { ProgressBar } from "../controls/ProgressBar.jsx";
import { ChangeId } from "../graph/ChangeId.jsx";
import { useSheetFocus } from "../surfaces/Dialog.jsx";

const ZS_KIND = { new: ["new", "new"], forward: ["forward", ""], backward: ["backwards", "warn"], sideways: ["sideways", "warn"], delete: ["delete", "warn"], none: ["up to date", "none"] };
// commit checks (jj checks every commit a ref or change would send) — three can be allowed by a flag: [reason, flag, chip, allow key]
const ZS_ALLOW = {
  "empty-description": ["has no description", "--allow-empty-description", "Allow empty descriptions", "emptyDescription"],
  private: ["is private (git.private-commits)", "--allow-private", "Allow private commits", "private"],
  conflicts: ["has conflicts", "--allow-conflicts", "Allow conflicts", "conflicts"],
};
// refusals without a flag: jj's reason, the command its hint names (none where jj names none), the plain explanation for Git
// switchers (one or two sentences, the Git term next to the jj one — sync #19) and the fix-it: a quiet chip that runs the hint's
// command (its tooltip the full command), then the sheet re-runs its dry runs
const ZS_HARD = {
  "no-author": { text: () => "has no author and/or committer set", help: () => "Git would take your name from user.name and user.email; jj needs them set too (Settings › General)." },
  conflicted: { text: (n, r) => (r ? n + "@" + r : n) + " is conflicted", hint: () => "jj git fetch",
    help: (n, r) => r ? "The remote's " + n + " moved two ways since your last fetch. Fetching brings it up to date." : "Your " + n + " points at more than one commit — like a branch that moved two ways. Point it at one commit first.",
    fix: (n, r) => r ? ["Fetch", "jj git fetch"] : null },
  "untracked-remote": { text: (n, r) => "an untracked " + n + "@" + r + " exists", hint: (n, r) => "jj bookmark track " + n + "@" + r,
    help: (n, r) => "In Git, " + n + " would follow " + r + "/" + n + ". jj links them only once you track " + n + "@" + r + " — then pushes and fetches keep them together.",
    fix: (n, r) => ["Track " + n + "@" + r, "jj bookmark track " + n + "@" + r] },
  "tracked-elsewhere": { text: (n, r, o) => "refusing to create new remote bookmark " + n + "@" + r + (o ? " — it is tracked on " + o : ""),
    help: (n, r) => "Like git push -u, the first push sets up tracking. Track " + n + "@" + r + " to push it there too.",
    fix: (n, r) => ["Track " + n + "@" + r, "jj bookmark track " + n + "@" + r] },
};
const zsList = (x) => (x == null ? [] : Array.isArray(x) ? x : [x]);
const zsKey = (b) => (b.type === "tag" ? "tag:" : "") + b.name;
// a ref's --dry-run result on one remote: its own entry in `remotes`, else the top-level fields (one remote, or the same everywhere)
const zsAt = (b, r) => (b.remotes ? b.remotes[r] || { kind: "none" } : b);
const zsSends = (b, r, byDefault) => { const t = zsAt(b, r); return t.kind !== "none" && (!byDefault || !!t.inDefault); };
// why jj would refuse a ref (or the change) on the remotes it goes to: commit reasons (some allowable), the local ref, each remote
function zsRefusal(b, to, allow, byDefault) {
  const top = zsList(b.refused);
  const commit = top.filter((x) => ZS_ALLOW[x] || x === "no-author");
  const open = commit.filter((x) => ZS_ALLOW[x] && !allow[ZS_ALLOW[x][3]]);
  const hard = [];
  if (commit.includes("no-author")) hard.push({ id: "no-author", commit: true });
  if (top.includes("conflicted")) hard.push({ id: "conflicted" });
  // in the preselection a ref goes only where it is in the default; otherwise (or ticked by hand) to every chosen remote
  const useDef = byDefault && to.some((r) => zsSends(b, r, true));
  if (b.remotes) to.forEach((r) => { if (!zsSends(b, r, useDef)) return; zsList(b.remotes[r].refused).forEach((id) => hard.push({ id, remote: r })); });
  return { commit, open, hard, blocked: open.length > 0 || hard.length > 0 };
}
const zsBulk = (rows, k, to) => rows.filter((b) => to.some((r) => { const t = zsAt(b, r); return t.kind !== "none" && (k === "deleted" ? t.kind === "delete" : t.kind !== "delete" && (k === "all" || t.tracked)); }));

// PushDialog — "Push" opens this sheet instead of pushing. A surface for exactly the parameters of `jj git push` (jj v0.46.0): nothing
// invented, no sequence of commands. The 18px modal sheet over the project window (one of the two sheets, with ConfirmDialog).
// · Preselection = what `jj git push` alone sends, per remote: tracked bookmarks in remote_bookmarks(remote=<r>)..@ (revsets.git-push)
//   and the tracked tags. Remotes: git.push (one name, a list or a pattern) — without it the only remote, else origin; no flag for those.
// · Rows: bookmarks and tags (TAG) — tick one → --bookmark <name> / --tag <name>. Bulk: Tracked (--tracked) · All (--all) · Deleted
//   (--deleted) — tags included. With more than one remote each row lists every remote: what happens there, or "not sent".
// · Push a change (@): --change @ → templates.git_push_bookmark ("push-" + short id), shown in advance; an edited name → --named <name>=@.
// · Kinds (--dry-run, per remote): new · forward · backwards · sideways · delete — the last three warn.
// · Refusals: jj refuses the WHOLE push while one refused commit or ref is in it, so a refused row can't be ticked. Commit reasons
//   (several at once: "has no description and has conflicts") — three with an Allow chip (--allow-empty-description / --allow-private /
//   --allow-conflicts), "no author" without; the ref itself (conflicted) or one remote (conflicted there, an untracked <name>@<r>, tracked
//   on another remote) — no chip, jj's hint command instead. The change (@) is checked the same way.
// · After: all pushed → the sheet closes, result toast. Some failed → state "done": per row and remote pushed · remote moved (the lease) ·
//   rejected (permissions, hooks); jj recorded the push (Undo works); Fetch where a lease failed; Done.
// · No click outside: the scrim does nothing (a sheet never closes by a click beside it) — Esc and Cancel cancel, ↩ pushes.
export function PushDialog({ remotes = ["origin"], defaultRemotes, defaultRemote = "origin", remote, onRemote, bookmarks = [], selected, onSelect, bulk = null, onBulk,
  change, onChange, allow = {}, onAllow, state = "ready", error, progress, results = [], onPush, onCancel, onDone, onFetch, onRetry, onFix, closing = false, scrim = true, width = 560 }) {
  const box = React.useRef(null);
  useSheetFocus(box, '[data-k="push"]');
  const defs = defaultRemotes || [defaultRemote];
  const to = remote || defs;
  const multi = to.length > 1;
  const rows = bookmarks.filter((b) => to.some((r) => zsSends(b, r, false) || zsAt(b, r).inDefault));
  const defKeys = rows.filter((b) => to.some((r) => zsSends(b, r, true))).map(zsKey);
  const sel = new Set(selected != null ? selected : defKeys);
  const chg = change ? zsRefusal({ refused: change.refused }, to, allow, false) : null;
  const withChange = !!(change && change.on && !chg.blocked);
  const selDefault = !bulk && !withChange && defKeys.length === sel.size && defKeys.every((k) => sel.has(k));
  // the bare command runs only while nothing it covers is refused — else every ref goes by name, to every chosen remote
  const byDefault = selDefault && rows.every((b) => !defKeys.includes(zsKey(b)) || !zsRefusal(b, to, allow, true).blocked);
  const done = state === "done", busy = state === "pushing";
  const ref = (b) => zsRefusal(b, to, allow, byDefault);
  // the change's one allowable reason: a short "Allow" at the end of its label line, the reason right below it (as a row's kind column)
  const chgInline = !!(chg && chg.open.length === 1 && !chg.hard.length && !done);
  const pushSet = rows.filter((b) => sel.has(zsKey(b)) && !ref(b).blocked);
  const cmd = PushDialog.command({ bookmarks, selected: [...sel], bulk, remotes: to, defaultRemotes: defs, change, allow });
  const warnN = pushSet.filter((b) => to.some((r) => (!byDefault || zsAt(b, r).inDefault) && ZS_KIND[zsAt(b, r).kind][1] === "warn")).length;
  const empty = !pushSet.length && !withChange;
  const res = (b, r) => results.find((x) => x.ref === zsKey(b) && x.remote === r);
  const okN = results.filter((x) => x.status === "pushed").length, leases = [...new Set(results.filter((x) => x.status === "lease").map((x) => x.remote))];
  const toggle = (k) => { const n = new Set(sel); n.has(k) ? n.delete(k) : n.add(k); onSelect && onSelect([...n]); onBulk && onBulk(null); };
  const pickBulk = (k) => { onSelect && onSelect(k === "default" ? defKeys : zsBulk(rows, k, to).map(zsKey)); onBulk && onBulk(k === "default" ? null : k); };
  const close = done ? onDone || onCancel : onCancel;
  const onKey = (e) => {
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); !busy && close && close(); }
    else if (e.key === "Enter" && !e.target.matches("input,textarea")) { e.preventDefault(); if (done) close && close(); else if (!empty && !busy) onPush && onPush(cmd); }
  };
  // inline (the kind column, one reason): "Allow" — the reason stands beside it; in the chip row under several reasons: the long label
  const allowChip = (id, short) => <Chip key={id} kind="toggle" size="sm" on={false} title={(short ? ZS_ALLOW[id][2] + " — " : "") + ZS_ALLOW[id][1]} onChange={() => onAllow && onAllow({ ...allow, [ZS_ALLOW[id][3]]: true })} onClick={(e) => e.stopPropagation()}>{short ? "Allow" : ZS_ALLOW[id][2]}</Chip>;
  // the sub-lines under a name: commit reasons, hard reasons with jj's hint, then the per-remote outcome of a push that failed in part
  const why = (b, rf, at, chipInline) => {
    const n = b.name, out = [];
    if (rf.commit.length) out.push(<span key="c" className="zs-push-sub is-refused">{rf.blocked && (rf.open.length || rf.hard.some((h) => h.commit)) ? "Refused — " : "Allowed — "}<ChangeId id={at} length={8}/> {rf.commit.map((x) => (ZS_ALLOW[x] ? ZS_ALLOW[x][0] : ZS_HARD[x].text())).join(" and ")}</span>);
    if (rf.open.length > (chipInline ? 1 : 0) && !rf.hard.length) out.push(<span key="a" className="zs-push-allow">{rf.open.map((id) => allowChip(id))}</span>);
    rf.hard.filter((h) => !h.commit).forEach((h, i) => {
      const o = h.id === "tracked-elsewhere" ? to.concat(remotes).filter((r, j, a) => a.indexOf(r) === j && r !== h.remote && b.remotes && b.remotes[r] && b.remotes[r].tracked).join(", ") : "";
      const hint = ZS_HARD[h.id].hint && ZS_HARD[h.id].hint(n, h.remote);
      out.push(<span key={"h" + i} className="zs-push-sub is-refused">Refused{multi && h.remote ? " on " + h.remote : ""} — {ZS_HARD[h.id].text(n, h.id === "conflicted" ? h.remote : h.remote, o)}{hint && <> · <code>{hint}</code></>}</span>);
      // sync #19: the plain explanation under jj's words, and the fix-it where jj's hint names a command
      const fix = ZS_HARD[h.id].fix && ZS_HARD[h.id].fix(n, h.remote);
      if (ZS_HARD[h.id].help) out.push(<span key={"x" + i} className="zs-push-help">{ZS_HARD[h.id].help(n, h.remote)}</span>);
      if (fix && !done) out.push(<span key={"f" + i} className="zs-push-fix"><Chip kind="action" size="sm" title={fix[1]} onClick={(e) => { e.stopPropagation(); onFix && onFix(fix[1]); }}>{fix[0]}</Chip></span>);
    });
    if (done) to.forEach((r) => { const x = res(b, r); if (!x || x.status === "pushed") return;
      out.push(<span key={"r" + r} className={"zs-push-sub " + (x.status === "lease" ? "is-refused" : "is-error")}>{PushDialog.outcomes[x.status].text(n, r, x.message)}</span>); });
    if (!out.length && !done && to.every((r) => !zsAt(b, r).tracked) && to.some((r) => zsAt(b, r).kind !== "delete" && zsAt(b, r).kind !== "none")) out.push(<span key="t" className="zs-push-sub">not tracked yet — the push tracks it</span>);
    return out;
  };
  const kindOf = (b, r, rf) => {
    const t = zsAt(b, r), x = done && res(b, r);
    if (x) { const o = PushDialog.outcomes[x.status]; return <span className={"zs-push-kind is-" + o.tone} title={x.message || undefined}>{o.icon && <Icon name={o.icon} size="sm"/>}{o.label(r)}</span>; }
    if (t.kind === "none") return <span className="zs-push-kind is-none">up to date</span>;
    if (rf.hard.some((h) => !h.remote || h.remote === r)) return <span className="zs-push-kind is-warn"><Icon name="conflict" size="sm"/>refused</span>;
    if (byDefault && !t.inDefault && to.some((x) => zsAt(b, x).inDefault)) return <span className="zs-push-kind is-none" title={"not in remote_bookmarks(remote=" + r + ")..@"}>not sent</span>;
    const k = ZS_KIND[t.kind] || ZS_KIND.forward;
    return <span className={"zs-push-kind" + (k[1] ? " is-" + k[1] : "")}>{k[1] === "warn" && <Icon name="conflict" size="sm"/>}{k[0]}</span>;
  };
  const move = (t) => <span className="zs-push-move">{t.from ? <ChangeId id={t.from} length={8}/> : <span className="zs-push-none">—</span>}<span className="zs-push-arrow">→</span>{t.to ? <ChangeId id={t.to} length={8}/> : <span className="zs-push-none">{t.kind === "none" ? "—" : "deleted"}</span>}</span>;
  const err = error && PushDialog.errors[error.kind];
  const hasTags = rows.some((b) => b.type === "tag");
  const sheet = (
    <div ref={box} role="dialog" aria-modal="true" aria-label="Push" className="zs-push" style={{ width }} onKeyDown={onKey}>
      <div className="zs-push-hd">
        <h2 className="zs-push-title">Push</h2>
        <div className="zs-push-to" role="group" aria-label="To remote"><span>to</span>
          {remotes.map((r) => <Chip key={r} kind="toggle" size="sm" mono on={to.includes(r)} disabled={busy || done} title={defs.includes(r) ? "git.push — no flag" : "--remote " + r}
            onChange={() => { const n = to.includes(r) ? to.filter((x) => x !== r) : [...to, r]; if (n.length) onRemote && onRemote(n); }}>{r}</Chip>)}
        </div>
      </div>
      <div className="zs-push-bd">
        {err && (
          <div className="zs-push-note is-error" role="alert">
            <Icon name="alert" size="md" className="zs-push-note-ic"/>
            <span className="zs-push-note-t">{err.text(error.remote || to[0])}</span>
            <Button size="sm" onClick={onRetry} title={cmd || undefined}>Try again</Button>
          </div>
        )}
        {done && (
          <div className="zs-push-note" role="status"><Icon name="conflict" size="md" className="zs-push-note-ic"/>
            <span className="zs-push-note-t">Pushed {okN} of {results.length} — the rest stayed as they were on {to.join(", ")}. The push is recorded, so Undo works as usual.</span>
            {leases.length > 0 && <Button size="sm" icon="fetch" title={"jj git fetch " + leases.map((r) => "--remote " + r).join(" ")} onClick={onFetch}>Fetch</Button>}
          </div>
        )}
        <section className="zs-push-sec" aria-label={hasTags ? "Bookmarks and tags" : "Bookmarks"}>
          <div className="zs-push-sec-hd"><span>{hasTags ? "Bookmarks and tags" : "Bookmarks"}</span>
            {!done && <span className="zs-push-bulk">
              {[["default", "As jj git push", to.map((r) => "remote_bookmarks(remote=" + r + ")..@").join(" · ") + " · tracked tags"], ["tracked", "Tracked", "--tracked"], ["all", "All", "--all"], ["deleted", "Deleted", "--deleted"]].map(([k, l, t]) => (
                <button key={k} type="button" className={"zs-push-bk" + ((k === "default" ? selDefault : bulk === k) ? " is-on" : "")} title={t} onClick={() => pickBulk(k)}>{l}</button>
              ))}
            </span>}
          </div>
          {rows.length ? (
            <div className="zs-push-list" role="group">
              {rows.map((b) => {
                const key = zsKey(b), rf = ref(b), blocked = rf.blocked, on = sel.has(key) && !blocked;
                const chipInline = !multi && rf.open.length === 1 && !rf.hard.length && !done;
                return (
                  <div key={key} className={"zs-push-row" + (on ? " is-sel" : "") + (blocked ? " is-refused" : "") + (multi ? " is-multi" : "")} onClick={() => !blocked && !done && !busy && toggle(key)}>
                    <Checkbox checked={on} disabled={blocked || done || busy} label={(b.type === "tag" ? "tag " : "") + b.name} onChange={() => toggle(key)} onClick={(e) => e.stopPropagation()}/>
                    <span className="zs-push-what">
                      <span className="zs-push-l1"><span className="zs-push-name">{b.name}</span>{b.type === "tag" && <span className="zs-push-type" title="--tag">tag</span>}</span>
                      {why(b, rf, b.refusedAt || (zsAt(b, to[0]).to || ""), chipInline)}
                    </span>
                    {multi ? (
                      <span className="zs-push-dests">{to.map((r) => <span key={r} className="zs-push-dest"><span className="zs-push-remote">{r}</span>{move(zsAt(b, r))}{kindOf(b, r, rf)}</span>)}</span>
                    ) : <>{move(zsAt(b, to[0]))}{chipInline ? allowChip(rf.open[0], true) : kindOf(b, to[0], rf)}</>}
                  </div>
                );
              })}
            </div>
          ) : <div className="zs-push-empty">No bookmark or tag has anything to send to {to.join(", ")}.</div>}
        </section>
        {change && (
          <section className={"zs-push-change" + (withChange ? " is-on" : "") + (chg.blocked ? " is-refused" : "")} aria-label="Push a change">
            <Checkbox checked={withChange} disabled={chg.blocked || done || busy} label="Push @ as a new bookmark" onChange={(v) => onChange && onChange({ ...change, on: v })}/>
            <div className="zs-push-change-t">
              <span className="zs-push-change-l"><span>Push <ChangeId id={change.id} length={8}/> as a new bookmark</span>{chgInline && allowChip(chg.open[0], true)}</span>
              {chg.commit.length || chg.hard.length ? <>
                <span className="zs-push-sub is-refused">{chg.blocked ? "Refused — " : "Allowed — "}<ChangeId id={change.refusedAt || change.id} length={8}/> {chg.commit.map((x) => (ZS_ALLOW[x] ? ZS_ALLOW[x][0] : ZS_HARD[x].text())).join(" and ")}{!chg.blocked && <> · pushed with <code>{chg.commit.map((x) => ZS_ALLOW[x][1]).join(" ")}</code></>}</span>
                {chg.open.length > (chgInline ? 1 : 0) && !chg.hard.length && <span className="zs-push-allow">{chg.open.map((id) => allowChip(id))}</span>}
              </> : null}
              <input className="zs-field zs-field--sm is-mono zs-push-change-in" value={change.name != null ? change.name : change.generated} disabled={!withChange || done || busy} spellCheck="false" aria-label="Bookmark name"
                onChange={(e) => onChange && onChange({ ...change, name: e.target.value })}/>
              <span className="zs-push-sub">{(change.name == null || change.name === change.generated) ? <>The name jj generates (<code>templates.git_push_bookmark</code>) — type your own to name it.</> : <>Your name — pushed with <code>--named</code>.</>}</span>
            </div>
          </section>
        )}
        {!empty && !done && warnN > 0 && (
          <div className="zs-push-note" role="note"><Icon name="conflict" size="md" className="zs-push-note-ic"/>
            <span className="zs-push-note-t">{warnN === 1 ? "One ref" : warnN + " refs"} will rewrite or remove history on {to.join(", ")} — moved backwards, sideways or deleted. jj checks each one against what you last fetched; one that has moved there since isn’t pushed.</span></div>
        )}
        {empty && !err && !done && <div className="zs-push-empty" role="status">Nothing to push. Choose a bookmark or tag{change ? ", or push @ as a new one" : ""}.</div>}
      </div>
      <div className="zs-push-ft">
        {busy ? <div className="zs-push-run" role="status"><ProgressBar value={progress} label="Pushing" width="100%"/><span>Pushing {pushSet.length + (withChange ? 1 : 0)} to {to.join(", ")}…</span></div>
          : <code className="zs-push-cmd" aria-label="Command">{cmd || "jj git push"}</code>}
        <div className="zs-push-btns">
          <span className="zs-push-hint">{done ? "Ran" : <>Checked with <code>--dry-run</code></>}</span>
          {done ? <Button size="md" variant="primary" data-k="push" onClick={close}>Done</Button> : <>
            <Button size="md" onClick={onCancel} disabled={busy}>Cancel</Button>
            <Button size="md" variant="primary" data-k="push" busy={busy} disabled={empty} onClick={() => onPush && onPush(cmd)} title={cmd || undefined}>Push</Button>
          </>}
        </div>
      </div>
    </div>
  );
  return scrim ? <div className={"zs-scrim" + (closing ? " is-closing" : "")}>{sheet}</div> : sheet;
}

// the exact command for a dialog state — minimal: no flags for the defaults, a bulk flag only when the selection IS that bulk choice,
// and never the bare command or a bulk flag while it would carry a refused ref (jj would refuse the whole push): then each ref by name
PushDialog.command = ({ bookmarks = [], selected = [], bulk = null, remotes, defaultRemotes, defaultRemote = "origin", change, allow = {} }) => {
  const defs = defaultRemotes || [defaultRemote], to = remotes || defs;
  const sel = new Set(selected);
  const rows = bookmarks.filter((b) => to.some((r) => zsSends(b, r, false)));
  const def = bookmarks.filter((b) => to.some((r) => zsSends(b, r, true)));
  const blocked = (b, byDefault) => zsRefusal(b, to, allow, byDefault).blocked;
  const withChange = !!(change && change.on && !zsRefusal({ refused: change.refused }, to, allow, false).blocked);
  const p = ["jj git push"];
  if (!(to.length === defs.length && to.every((r) => defs.includes(r)))) to.forEach((r) => p.push("--remote " + r));
  const isDefault = !bulk && !withChange && def.length === sel.size && def.every((b) => sel.has(zsKey(b)));
  if (isDefault && def.length && !def.some((b) => blocked(b, true))) return p.join(" ");
  const send = rows.filter((b) => sel.has(zsKey(b)) && !blocked(b, false));
  if (!send.length && !withChange) return "";
  const covered = bulk && zsBulk(rows, bulk, to);
  if (covered && !withChange && covered.length === send.length && covered.every((b) => sel.has(zsKey(b)) && !blocked(b, false))) p.push("--" + bulk);
  else send.forEach((b) => p.push((b.type === "tag" ? "--tag " : "--bookmark ") + b.name));
  if (withChange) { const nm = change.name; p.push(nm != null && nm !== change.generated && nm.trim() ? "--named " + nm.trim() + "=@" : "--change @"); }
  const reasons = new Set([...send.flatMap((b) => zsList(b.refused)), ...(withChange ? zsList(change.refused) : [])]);
  Object.entries(ZS_ALLOW).forEach(([k, v]) => { if (reasons.has(k) && allow[v[3]]) p.push(v[1]); });
  return p.join(" ");
};
// errors that stop the whole push before anything is sent
PushDialog.errors = {
  network: { text: (r) => "Couldn’t reach " + r + ". Check the connection, then try again." },
  auth: { text: (r) => r + " refused the credentials. Check your SSH key or token, then try again." },
};
// per ref and remote after a push — jj checks the lease ref by ref and pushes the rest ("Failed to push some bookmarks")
PushDialog.outcomes = {
  pushed: { tone: "new", icon: "check", label: () => "pushed", text: () => "" },
  lease: { tone: "warn", icon: "conflict", label: (r) => "moved on " + r, text: (n, r) => r + " has moved " + n + " since the last fetch. Fetch, point " + n + " where it should be, then push again." },
  rejected: { tone: "error", icon: "alert", label: () => "rejected", text: (n, r, m) => r + " rejected the update" + (m ? ": " + m : "") + "." },
};
