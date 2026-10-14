import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { SearchScopes, SearchDollar } from "./GraphSearch.jsx";

// SearchMenu — the one menu left of the field, in this order: the default search (tag Default) · the other jj log variants,
// built-ins and configurations ($ glyph, name, expression) · Go to (Change, Bookmark) · Filter by (Author, File, Description), each
// with its prefix · Edit Configurations…. The row of what the graph shows is selected; the scope row of an active search shows its value.
// variants: [{ id, name, builtin, desc (built-ins) | expr (configurations), cmd }] in menu order — the first is the default search.
export function SearchMenu({ variants = SearchMenu.builtins, current, scope, value, onPickVariant, onPickScope, onEdit, autoFocus = false, className = "", style }) {
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (!autoFocus || !ref.current) return;
    const b = ref.current.querySelector(".zs-gs-srow.is-on") || ref.current.querySelector(".zs-gs-srow");
    if (b) b.focus({ preventScroll: true });
  }, [autoFocus]);
  const arrows = (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    const bs = [...e.currentTarget.querySelectorAll("button")], i = bs.indexOf(document.activeElement);
    const n = bs[(i + (e.key === "ArrowDown" ? 1 : -1) + bs.length) % bs.length];
    if (n) n.focus();
  };
  const vRow = (v, first) => {
    const on = current === v.id;
    return (
      <button key={"v:" + v.id} type="button" role="option" aria-selected={on} className={"zs-gs-srow zs-gs-vrow" + (on ? " is-on" : "")}
        onClick={() => onPickVariant && onPickVariant(v.id)} title={v.cmd || (v.expr ? "jj log -r '" + v.expr + "'" : undefined)}>
        <span className="zs-gs-ic"><SearchDollar/></span>
        <span className="zs-gs-sl">{v.builtin ? <code>{v.name}</code> : v.name || "Unnamed"}</span>
        <span className={"zs-gs-sd" + (v.builtin ? "" : " is-mono")}>{v.builtin ? v.desc : v.expr}</span>
        {first ? <span className="zs-gs-tag">Default</span> : <span></span>}
      </button>
    );
  };
  const sRow = (id) => {
    const s = SearchScopes[id], on = scope === id;
    return (
      <button key={id} type="button" role="option" aria-selected={on} className={"zs-gs-srow" + (on ? " is-on" : "")} onClick={() => onPickScope && onPickScope(id)}>
        <span className="zs-gs-ic"><Icon name={s.icon} size={14}/></span>
        <span className="zs-gs-sl">{s.label}</span>
        <span className={"zs-gs-sd" + (on ? " is-val" : s.go ? "" : " is-mono")}>{on ? value : s.desc}</span>
        <kbd className="zs-gs-kbd">{s.prefix}</kbd>
      </button>
    );
  };
  return (
    <div className={("zs-gs-menu " + className).trim()} role="listbox" aria-label="Search menu" onKeyDown={arrows} ref={ref} style={style}>
      {variants.map((v, i) => vRow(v, i === 0))}
      <div className="zs-gs-msep"></div>
      <div className="zs-gs-gh"><span>Go to</span><em>selects a change · graph stays</em></div>
      {["change", "bookmark"].map(sRow)}
      <div className="zs-gs-gh"><span>Filter by</span><em>redraws the graph</em></div>
      {["author", "file", "description"].map(sRow)}
      <div className="zs-gs-msep"></div>
      <button type="button" className="zs-gs-srow zs-gs-edit" onClick={onEdit}>
        <span className="zs-gs-ic"><Icon name="settings" size={13}/></span>
        <span className="zs-gs-sl">Edit Configurations…</span>
      </button>
    </div>
  );
}
SearchMenu.builtins = [
  { id: "default", name: "jj log", desc: "Your mutable changes plus trunk context", cmd: "jj log", builtin: true },
  { id: "all", name: "all()", desc: "Every visible commit, incl. immutable history", cmd: "jj log -r 'all()'", builtin: true },
];
