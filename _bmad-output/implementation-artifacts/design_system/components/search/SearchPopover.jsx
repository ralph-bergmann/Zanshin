import React from "react";
import { Icon } from "../brand/Icon.jsx";

// SearchPopover — the suggestions under the graph search, in menu material. Empty field: recent searches (go-tos and filters, with
// their change counts). While typing: matches grouped by kind (Changes, Bookmarks, Authors, Files, Descriptions).
// footer states what Enter does: { text, verb } — the full `jj log -r '…'` command with "Filter", or
// "Selects the change — the graph stays as it is" with "Select".
export function SearchPopover({ note, empty, footer, children, listRef, className = "", style, ...rest }) {
  return (
    <div className={("zs-gs-pop " + className).trim()} style={style} onMouseDown={(e) => { if (!e.target.closest("input")) e.preventDefault(); }} {...rest}>
      <div className="zs-gs-list" role="listbox" aria-label="Suggestions" ref={listRef}>
        {note && <div className="zs-gs-note">{note}</div>}
        {children}
        {empty && <div className="zs-gs-empty">{empty}</div>}
      </div>
      {footer && (
        <div className="zs-gs-ft">
          <span className="zs-gs-ft-t" title={typeof footer.text === "string" ? footer.text : undefined}>{footer.text}</span>
          <span className="zs-gs-ft-k">{footer.verb || "Select"}<kbd className="zs-gs-kbd">↵</kbd></span>
        </div>
      )}
    </div>
  );
}

// SearchGroup — a group header in the small-caps menu style; a quiet note (em) or an action (Clear) on the right.
export function SearchGroup({ label, note, action, onAction }) {
  return (
    <div className="zs-gs-gh"><span>{label}</span>{note && <em>{note}</em>}{action && <button type="button" onClick={onAction}>{action}</button>}</div>
  );
}

// SearchRow — one 34px suggestion: icon · before + label (+ quote, sub, after) · meta. highlighted = moon tint, icon in moon.
// mono = a path (folder part dimmed via SearchMatch split); dim = "(no description set)"; more = "3 more in Files" row with a chevron.
export function SearchRow({ icon, label, quote, before, after, sub, mono = false, dim = false, meta, highlighted = false, more = false, onClick, onMouseMove, className = "", ...rest }) {
  return (
    <div role="option" aria-selected={highlighted} className={"zs-gs-row" + (highlighted ? " is-on" : "") + (more ? " is-more" : "") + (className ? " " + className : "")} onClick={onClick} onMouseMove={onMouseMove} {...rest}>
      <span className="zs-gs-ic">{typeof icon === "string" ? <Icon name={icon} size={14}/> : icon}</span>
      <span className="zs-gs-main">
        {before}
        {more ? <span className="zs-gs-more">{label}</span>
          : label != null && <span className={mono ? "zs-gs-path" : "zs-gs-nm" + (dim ? " is-dim" : "")}>{label}{quote != null && <> <span className="zs-gs-qt">“{quote}”</span></>}</span>}
        {sub && <code className="zs-gs-sub">{sub}</code>}
        {after}
      </span>
      <span className="zs-gs-meta">{more ? <Icon name="chevron-right" size={12}/> : meta}</span>
    </div>
  );
}

// SearchMatch — the match underlined in moon (600, 1.5px, 3px offset); everything before `split` dimmed (a path's folder part).
// match: [start, end] or the query string (found case-insensitively, after `split` first).
export function SearchMatch({ text = "", match, split = 0 }) {
  let r = match;
  if (typeof match === "string") {
    const t = text.toLowerCase(), q = match.toLowerCase();
    let i = q ? t.indexOf(q, split) : -1;
    if (i < 0 && q) i = t.indexOf(q);
    r = i < 0 ? null : [i, i + q.length];
  }
  const s = r ? r[0] : -1, e = r ? r[1] : -1;
  const cuts = [...new Set([0, split, s, e, text.length])].filter((x) => x >= 0 && x <= text.length).sort((a, b) => a - b);
  const out = [];
  for (let i = 0; i < cuts.length - 1; i++) {
    const a = cuts[i], b = cuts[i + 1];
    if (a === b) continue;
    const cls = [a < split && "zs-gs-d", r && a >= s && b <= e && "zs-gs-m"].filter(Boolean).join(" ");
    out.push(cls ? <span key={a} className={cls}>{text.slice(a, b)}</span> : <React.Fragment key={a}>{text.slice(a, b)}</React.Fragment>);
  }
  return <>{out}</>;
}

// SearchTag — "not in view", "glob", "you · mine()", "Default"
export function SearchTag({ children }) {
  return <span className="zs-gs-tag">{children}</span>;
}

// SearchAvatar — an author's initial (moon ring on the highlighted row)
export function SearchAvatar({ name = "" }) {
  return <span className="zs-gs-av" aria-hidden="true">{name.trim().slice(0, 1)}</span>;
}
