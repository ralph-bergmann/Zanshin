import React from "react";

// Badge — a count on an icon button or a nav row (Fetch: incoming changes). tone accent = something to act on · neutral = just a count.
// Appears scaling .6 → 1 with a fade; a new number rises 5px into place (--dur-toggle, glide); 0 hides it with the exit. true = a dot.
export function Badge({ count, max = 99, tone = "accent", label, className = "" }) {
  const show = count != null && count !== false && count !== 0;
  const [mounted, setMounted] = React.useState(show);
  const [closing, setClosing] = React.useState(false);
  const last = React.useRef(count);
  React.useEffect(() => {
    if (show) { setMounted(true); setClosing(false); last.current = count; return; }
    if (!mounted) return;
    setClosing(true);
    const t = setTimeout(() => { setMounted(false); setClosing(false); }, 120);
    return () => clearTimeout(t);
  }, [show, count]);
  if (!mounted) return null;
  const v = show ? count : last.current;
  const dot = v === true;
  const txt = dot ? "" : typeof v === "number" && v > max ? max + "+" : String(v);
  return (
    <span className={["zs-badge", tone === "neutral" && "zs-badge--neutral", dot && "is-dot", closing && "is-closing", className].filter(Boolean).join(" ")} aria-label={label} aria-hidden={label ? undefined : true}>
      {!dot && <span key={txt} className="zs-badge-n">{txt}</span>}
    </span>
  );
}
