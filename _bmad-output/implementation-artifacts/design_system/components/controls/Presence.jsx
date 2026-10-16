import React from "react";

// Presence — keeps a closing layer mounted for its exit. children is a function of `closing`; pass it on as the component's closing prop.
// exit: ms, default --dur-exit (120). Dialogs and toasts use 180 (--dur-exit-lg).
export function Presence({ open, exit = 120, children }) {
  const [mounted, setMounted] = React.useState(!!open);
  const [closing, setClosing] = React.useState(false);
  React.useEffect(() => {
    if (open) { setMounted(true); setClosing(false); return; }
    if (!mounted) return;
    setClosing(true);
    const t = setTimeout(() => { setMounted(false); setClosing(false); }, exit);
    return () => clearTimeout(t);
  }, [open]);
  return mounted ? children(closing) : null;
}
