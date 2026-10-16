import React from "react";

// Radio — 15px circle; on = accent fill with a 6px ink dot that grows in (--dur-toggle, glide).
export function Radio({ checked = false, onChange, label, hint, disabled = false, children, buttonRef, tabIndex, onKeyDown, className = "", ...rest }) {
  const text = children != null ? children : label;
  return (
    <label className={["zs-radio-row", disabled && "is-disabled", className].filter(Boolean).join(" ")}>
      <button ref={buttonRef} type="button" role="radio" aria-checked={checked} disabled={disabled} tabIndex={tabIndex} onKeyDown={onKeyDown}
        aria-label={text == null ? label : undefined} className={"zs-radio" + (checked ? " is-on" : "")} onClick={() => onChange && onChange(true)} {...rest}>
        <span className="zs-radio-dot"></span>
      </button>
      {text != null && <span className="zs-radio-l"><span>{text}</span>{hint && <span className="zs-radio-hint">{hint}</span>}</span>}
    </label>
  );
}

// RadioGroup — one tab stop (the chosen radio); ↑/↓ (←/→) move and choose, skipping disabled options.
export function RadioGroup({ options = [], value, onChange, label, direction = "column", disabled = false, className = "" }) {
  const refs = React.useRef([]);
  const opts = options.map((o) => (typeof o === "string" ? { value: o, label: o } : o));
  const idx = opts.findIndex((o) => o.value === value);
  const stop = idx >= 0 ? idx : opts.findIndex((o) => !o.disabled);
  const move = (from, dir) => {
    for (let k = 1; k <= opts.length; k++) {
      const j = (from + dir * k + opts.length * 2) % opts.length;
      if (!opts[j].disabled) { onChange && onChange(opts[j].value); refs.current[j] && refs.current[j].focus(); return; }
    }
  };
  return (
    <div role="radiogroup" aria-label={label} className={["zs-radiogroup", direction === "row" && "is-row", className].filter(Boolean).join(" ")}>
      {opts.map((o, i) => (
        <Radio key={o.value} buttonRef={(el) => (refs.current[i] = el)} tabIndex={i === stop ? 0 : -1} checked={o.value === value} disabled={disabled || o.disabled}
          hint={o.hint} title={o.title} onChange={() => onChange && onChange(o.value)}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown" || e.key === "ArrowRight") { e.preventDefault(); move(i, 1); }
            else if (e.key === "ArrowUp" || e.key === "ArrowLeft") { e.preventDefault(); move(i, -1); }
          }}>{o.label}</Radio>
      ))}
    </div>
  );
}
