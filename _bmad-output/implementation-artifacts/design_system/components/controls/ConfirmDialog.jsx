import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Button } from "../actions/Button.jsx";
import { useSheetFocus } from "../surfaces/Dialog.jsx";

// ConfirmDialog — only for what jj undo can't take back. Everything else acts and offers Undo; pushing has its own sheet (PushDialog).
// tone destructive: the filled red button is the dialog's one primary; focus starts on Cancel, ↩ = the focused button, ⌘↩ confirms.
// tone warn / default: the gold primary, focused, ↩ confirms. Esc and Cancel cancel — a click on the scrim does nothing; Tab stays inside; focus returns.
// The 18px modal sheet (--dur-dialog in, glide; --dur-exit-lg out).
export function ConfirmDialog({ title, children, cmd, confirmLabel = "Confirm", cancelLabel = "Cancel", tone = "destructive", onConfirm, onCancel, busy = false, closing = false, scrim = true, width = 420 }) {
  const box = React.useRef(null);
  const id = React.useId();
  const destructive = tone === "destructive";
  useSheetFocus(box, destructive ? '[data-k="cancel"]' : '[data-k="ok"]');
  const onKey = (e) => {
    if (e.key === "Escape") { e.preventDefault(); onCancel && onCancel(); }
    else if (e.key === "Enter" && (destructive ? e.metaKey || e.ctrlKey : true)) { e.preventDefault(); onConfirm && onConfirm(); }
  };
  const sheet = (
    <div ref={box} role="alertdialog" aria-modal="true" aria-labelledby={id + "t"} aria-describedby={id + "d"} className={"zs-alert is-" + tone}
      style={{ width }} onKeyDown={onKey} onMouseDown={(e) => e.stopPropagation()}>
      <div className="zs-alert-hd">
        {tone === "warn" && <Icon name="conflict" size="lg" className="zs-alert-ic" />}
        <h2 id={id + "t"} className="zs-alert-title">{title}</h2>
      </div>
      <div id={id + "d"} className="zs-alert-body">{children}</div>
      {cmd && <code className="zs-alert-cmd">{cmd}</code>}
      <div className="zs-alert-ft">
        {destructive && <span className="zs-alert-key">⌘↩ confirms</span>}
        <Button size="md" data-k="cancel" onClick={onCancel}>{cancelLabel}</Button>
        <Button size="md" data-k="ok" variant={destructive ? "destructive" : "primary"} busy={busy} onClick={onConfirm} title={destructive ? "⌘↩" : "↩"}>{confirmLabel}</Button>
      </div>
    </div>
  );
  return scrim ? <div className={"zs-scrim" + (closing ? " is-closing" : "")}>{sheet}</div> : sheet;
}
