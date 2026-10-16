import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { SearchScopes, SearchDollar } from "./GraphSearch.jsx";

const ZS_SCOPE_ROWS = ["change", "bookmark", "author", "file", "description"];

// SearchMenu — the one menu left of the field, in this order: the default search (tag Default) · the other jj log variants,
// built-ins and configurations ($ glyph, name, expression) · Go to (Change, Bookmark) · Filter by (Author, File, Description), each
// with its prefix · Edit Configurations….
// A FIELD-ATTACHED list (readme › Control states, rule 4): focus stays in the search field. The keyboard row (`active`, named by the
// field's aria-activedescendant) is --accent-soft with its icon in accent; hover is --fl-hover; what the graph shows — the current
// variant, or the scope of the active typed search (its row shows the value) — carries a check, never the fill.
// Keys come from the field: SearchMenu.navigate(e, active, SearchMenu.count(variants)) → the new index (↑ ↓ Home End), or null.
// variants: [{ id, name, builtin, desc (built-ins) | expr (configurations), cmd }] in menu order — the first is the default search.
export function SearchMenu({ variants = SearchMenu.builtins, current, scope, value, active, onPickVariant, onPickScope, onEdit, listId = "zs-gs-menu", className = "", style }) {
  const act = active != null ? active : -1;
  const keep = (e) => e.preventDefault(); // a click must not take focus from the field
  const row = (i, cls, onPick, title, kids, selected) => (
    <div key={i} id={listId + "-" + i} role="option" aria-selected={i === act} aria-current={selected || undefined}
      className={"zs-gs-srow " + cls + (i === act ? " is-active" : "") + (selected ? " is-current" : "")}
      onMouseDown={keep} onClick={onPick} title={title}>{kids}</div>
  );
  const n = variants.length;
  return (
    <div id={listId} className={("zs-gs-menu " + className).trim()} role="listbox" aria-label="Search menu" style={style}>
      {variants.map((v, i) => row(i, "zs-gs-vrow", () => onPickVariant && onPickVariant(v.id), v.cmd || (v.expr ? "jj log -r '" + v.expr + "'" : undefined), <>
        <span className="zs-gs-ic"><SearchDollar/></span>
        <span className="zs-gs-sl">{v.builtin ? <code>{v.name}</code> : v.name || "Unnamed"}</span>
        <span className={"zs-gs-sd" + (v.builtin ? "" : " is-mono")}>{v.builtin ? v.desc : v.expr}</span>
        <span className="zs-gs-end">{i === 0 && <span className="zs-gs-tag">Default</span>}{current === v.id && <Icon name="check" size="sm" className="zs-gs-chk"/>}</span>
      </>, current === v.id))}
      <div className="zs-gs-msep"></div>
      <div className="zs-gs-gh"><span>Go to</span><em>selects a change · graph stays</em></div>
      {ZS_SCOPE_ROWS.slice(0, 2).map((id, k) => scopeRow(id, n + k))}
      <div className="zs-gs-gh"><span>Filter by</span><em>redraws the graph</em></div>
      {ZS_SCOPE_ROWS.slice(2).map((id, k) => scopeRow(id, n + 2 + k))}
      <div className="zs-gs-msep"></div>
      {row(n + 5, "zs-gs-edit", onEdit, undefined, <>
        <span className="zs-gs-ic"><Icon name="settings" size="md"/></span>
        <span className="zs-gs-sl">Edit Configurations…</span>
      </>)}
    </div>
  );
  function scopeRow(id, i) {
    const s = SearchScopes[id], on = scope === id;
    return row(i, "", () => onPickScope && onPickScope(id), undefined, <>
      <span className="zs-gs-ic"><Icon name={s.icon} size="md"/></span>
      <span className="zs-gs-sl">{s.label}</span>
      <span className={"zs-gs-sd" + (on ? " is-val" : s.go ? "" : " is-mono")}>{on ? value : s.desc}</span>
      <span className="zs-gs-end">{on && <Icon name="check" size="sm" className="zs-gs-chk"/>}<kbd className="zs-gs-kbd">{s.prefix}</kbd></span>
    </>, on);
  }
}
SearchMenu.builtins = [
  { id: "default", name: "jj log", desc: "Your mutable changes plus trunk context", cmd: "jj log", builtin: true },
  { id: "all", name: "all()", desc: "Every visible commit, incl. immutable history", cmd: "jj log -r 'all()'", builtin: true },
];
// rows in the menu: the variants, five scopes, Edit Configurations…
SearchMenu.count = (variants = SearchMenu.builtins) => variants.length + 6;
// the field's keys for an open list: ↑ ↓ (wrap) Home End → the new keyboard row; anything else → null (↩ and Esc stay with the field)
SearchMenu.navigate = (e, active, count) => {
  if (!count) return null;
  if (e.key === "ArrowDown") return active < 0 ? 0 : (active + 1) % count;
  if (e.key === "ArrowUp") return active < 0 ? count - 1 : (active - 1 + count) % count;
  if (e.key === "Home") return 0;
  if (e.key === "End") return count - 1;
  return null;
};
