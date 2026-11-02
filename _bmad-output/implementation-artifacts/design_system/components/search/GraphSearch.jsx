import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Scopes of the graph search. Go to (Change, Bookmark) selects a change and leaves the graph as it is; Filter by (Author, File,
// Description) redraws it — a typed search replaces the view and runs in all(). "Any" has no menu row: it is the field without a scope.
export const SearchScopes = {
  any: { label: "Any", icon: "search", placeholder: "Search changes, bookmarks, authors, files…", short: "Search…" },
  change: { label: "Change", icon: "change", go: true, prefix: "c:", desc: "change ID · commit ID · description", placeholder: "Change ID, commit ID or description", short: "Change ID or hash", mono: true },
  bookmark: { label: "Bookmark", icon: "bookmark", go: true, prefix: "b:", desc: "name", placeholder: "Bookmark name" },
  author: { label: "Author", icon: "user", prefix: "a:", desc: "author()", placeholder: "Author name" },
  file: { label: "File", icon: "file", prefix: "f:", desc: "files()", placeholder: "Path, folder or glob", short: "Path or glob", mono: true },
  description: { label: "Description", icon: "description", prefix: "d:", desc: "description()", placeholder: "Text in descriptions", short: "Text" },
};
const ZS_GS_PRE = { c: "change", change: "change", commit: "change", b: "bookmark", bookmark: "bookmark", a: "author", author: "author", f: "file", file: "file", files: "file", d: "description", desc: "description", description: "description" };
const ZS_GS_PRE_RE = /^(c|change|commit|b|bookmark|a|author|f|files?|d|desc|description):\s*/i;

// `$` marks a jj log variant that draws the graph — menu rows, and the pill while the field rests on a variant.
export function SearchDollar() {
  return <span className="zs-gs-dollar" aria-hidden="true">$</span>;
}

// GraphSearch — the View capsule's field: [menu ▾ | query | ✕]. It holds one thing:
//   view "default" — the default search: empty field, calm pill, ⌘F hint, no ✕, so you can type straight away
//   view "search"  — a typed search: scope icon + label, the value, ✕ (the pill keeps its default look)
//   view "variant" — another jj log variant: the pill shows $, the field shows the variant's name as a value; clicking in empties it
// ✕ always returns to the default search. Typed prefixes c: b: a: f: d: switch the scope; Backspace in an empty field returns to Any;
// ⌘F or / focuses the field. Popovers (SearchMenu, SearchPopover) go in as children and anchor under the field.
// Field-attached lists: focus STAYS in this input. ↑/↓ move the keyboard row of the open list (SearchMenu / SearchPopover), which the
// input names with aria-activedescendant (pass activeDescendant + controls); ↩ runs that row, Esc closes the list, a click runs any row.
export function GraphSearch({ scope = "any", value = "", view = "default", variantName = "", variantMono = false, defaultName = "jj log",
  focused, menuOpen = false, size = "full", placeholder, hotkey = true, expanded = false, activeDescendant, controls,
  onChange, onScopeChange, onMenu, onClear, onKeyDown, onFocus, onBlur, onMouseUp, inputRef, children, className = "", style }) {
  const [hasFocus, setHasFocus] = React.useState(false);
  const own = React.useRef(null), ref = inputRef || own;
  const focus = focused != null ? focused : hasFocus;
  const sc = SearchScopes[scope] || SearchScopes.any;
  const atDefault = view === "default", showVariant = !focus && view === "variant";
  React.useEffect(() => {
    if (!hotkey) return undefined;
    const k = (e) => {
      const el = e.target, typing = el && (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable);
      const cmdF = (e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "f";
      if (cmdF || (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey && !e.altKey)) { e.preventDefault(); const i = ref.current; if (i) { i.focus(); i.select(); } }
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [hotkey]);
  const change = (e) => {
    let v = e.target.value;
    const m = v.match(ZS_GS_PRE_RE);
    if (m && onScopeChange) { onScopeChange(ZS_GS_PRE[m[1].toLowerCase()]); v = v.slice(m[0].length); }
    if (onChange) onChange(v, e);
  };
  const key = (e) => {
    if (e.key === "Backspace" && !value && scope !== "any" && onScopeChange) { e.preventDefault(); onScopeChange("any"); }
    if (onKeyDown) onKeyDown(e);
  };
  const title = focus || view === "search" ? "Search in: " + sc.label + (sc.go ? " — selects a change" : scope === "any" ? "" : " — filters the graph")
    : atDefault ? "Default search: " + defaultName : "Showing " + variantName;
  const inCls = "zs-gs-in" + (showVariant ? " is-val" + (variantMono ? " is-mono" : "") : sc.mono ? " is-mono" : "");
  const ph = placeholder || (showVariant ? variantName : size === "narrow" ? sc.short || sc.placeholder : sc.placeholder);
  return (
    <div className={["zs-gs", focus && "is-focus", !atDefault && "has-q", size !== "full" && "is-" + size, className].filter(Boolean).join(" ")} style={style}>
      <button type="button" className={"zs-gs-scope" + (showVariant || scope === "any" ? " is-any" : "") + (menuOpen ? " is-open" : "")} onClick={onMenu}
        aria-haspopup="listbox" aria-expanded={menuOpen} aria-label="Search menu" title={title}>
        {showVariant ? <SearchDollar/> : <><Icon name={sc.icon} size="md"/>{scope !== "any" && <span className="zs-gs-sl">{sc.label}</span>}</>}
        <Icon name="chevron-down" size="sm" className="zs-gs-chev"/>
      </button>
      <input ref={ref} className={inCls} value={value} placeholder={ph} spellCheck="false" autoComplete="off" role="combobox" aria-label="Search the graph" aria-expanded={expanded || menuOpen} aria-autocomplete="list" aria-controls={controls} aria-activedescendant={activeDescendant}
        onChange={change} onKeyDown={key} onMouseUp={onMouseUp}
        onFocus={(e) => { setHasFocus(true); if (onFocus) onFocus(e); }} onBlur={(e) => { setHasFocus(false); if (onBlur) onBlur(e); }}/>
      {!value && !focus && atDefault && size !== "narrow" && <kbd className="zs-gs-k" aria-hidden="true">⌘F</kbd>}
      {(value || !atDefault) && (
        <button type="button" className="zs-gs-x" onMouseDown={(e) => { if (focus) e.preventDefault(); }} onClick={onClear}
          aria-label={atDefault ? "Clear" : "Back to the default search"} title={atDefault ? "Clear" : "Back to the default search — " + defaultName}>
          <Icon name="close" size="xs"/>
        </button>
      )}
      {children}
    </div>
  );
}
// the client's width steps: input 320 · 250 (≤1180) · pill icon only (≤1100) · 170, no ⌘F, short placeholders (≤980)
GraphSearch.sizeFor = (w) => (w <= 980 ? "narrow" : w <= 1100 ? "compact" : w <= 1180 ? "medium" : "full");
