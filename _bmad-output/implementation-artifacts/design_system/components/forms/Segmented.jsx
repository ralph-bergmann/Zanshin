import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Segmented — 2–4 mutually exclusive options. options: ["A","B"] or [{ value, label, icon, title, disabled }]
// variant: default 26 (View options) · tabs 36 (the Settings window's header: General | Project) · inset 30 (inside a settings row, darker track)
// size sm 22: icon-only toggles in a diff toolbar. Segment heights are the control minus twice the inset (22 · 30 · 26 · 18).
// A thumb slides to the chosen segment (--dur-toggle, glide; Reduce motion: it is simply there). Hover brightens the label only.
// A disabled segment is aria-disabled (no hover, no press, skipped by the arrows) inside a wrapper whose title gives the reason.
// Keyboard: one tab stop (the chosen segment); ←/→ (and ↑/↓) move and choose, skipping disabled ones. VoiceOver: radio group (tabs: tab list).
export function Segmented({ options = [], value, onChange, label, variant = "default", size = "md", role = "radiogroup", className = "" }) {
  const tabs = variant === "tabs";
  const refs = React.useRef([]);
  const [thumb, setThumb] = React.useState(null);
  const [live, setLive] = React.useState(false);
  const opts = options.map((o) => (typeof o === "string" ? { value: o, label: o } : o));
  const idx = opts.findIndex((o) => o.value === value);
  const measure = React.useCallback(() => {
    const el = refs.current[idx];
    setThumb(el ? { x: el.offsetLeft, w: el.offsetWidth } : null);
  }, [idx]);
  React.useLayoutEffect(() => { measure(); }, [measure, options.length]);
  React.useEffect(() => {
    const t = requestAnimationFrame(() => setLive(true));
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(() => measure()) : null;
    if (ro) refs.current.forEach((el) => el && ro.observe(el));
    return () => { cancelAnimationFrame(t); ro && ro.disconnect(); };
  }, [measure]);
  const move = (from, dir) => {
    for (let k = 1; k <= opts.length; k++) {
      const j = (from + dir * k + opts.length) % opts.length;
      if (!opts[j].disabled) { onChange && onChange(opts[j].value); refs.current[j] && refs.current[j].focus(); return; }
    }
  };
  const onKey = (e, i) => {
    if (e.key === "ArrowRight" || e.key === "ArrowDown") { e.preventDefault(); move(i, 1); }
    else if (e.key === "ArrowLeft" || e.key === "ArrowUp") { e.preventDefault(); move(i, -1); }
  };
  const cls = ["zs-seg", variant !== "default" && "zs-seg--" + variant, size === "sm" && "zs-seg--sm", thumb && "has-thumb", className].filter(Boolean).join(" ");
  const tabStop = idx >= 0 ? idx : opts.findIndex((o) => !o.disabled);
  return (
    <div className={cls} role={tabs ? "tablist" : role} aria-label={label}>
      {thumb && <span className="zs-seg-thumb" aria-hidden="true" style={{ width: thumb.w, transform: "translateX(" + thumb.x + "px)", transitionDuration: live ? undefined : "0ms" }}></span>}
      {opts.map((o, i) => {
        const on = o.value === value;
        const btn = (
          <button key={o.value} ref={(el) => (refs.current[i] = el)} type="button" role={tabs ? "tab" : "radio"} aria-checked={tabs ? undefined : on} aria-selected={tabs ? on : undefined}
            aria-disabled={o.disabled || undefined} aria-description={o.disabled && o.title ? o.title : undefined} tabIndex={i === tabStop && !o.disabled ? 0 : -1}
            aria-label={!o.label && o.title ? o.title : undefined} className={"zs-seg-btn" + (on ? " is-on" : "")} title={o.disabled ? undefined : o.title}
            onKeyDown={(e) => onKey(e, i)} onClick={() => !o.disabled && onChange && onChange(o.value)}>
            {o.icon && (typeof o.icon === "string" ? <Icon name={o.icon} size={tabs ? "md" : "sm"} /> : o.icon)}
            {o.label}
          </button>
        );
        return o.disabled ? <span key={o.value} className="zs-seg-why" title={o.title}>{btn}</span> : btn;
      })}
    </div>
  );
}
