import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Button } from "../actions/Button.jsx";
import { useSheetFocus } from "../surfaces/Dialog.jsx";

// ConfirmDialog — only for what jj undo can't take back. Everything else acts and offers Undo; pushing has its own sheet (PushDialog).
// tone destructive: the filled red button is the dialog's one primary; focus starts on Cancel, ↩ = the focused button, ⌘↩ confirms.
// tone warn / default: the gold primary, focused, ↩ confirms. Esc and Cancel cancel — a click on the scrim does nothing; Tab stays inside; focus returns.
// The 18px modal sheet (--dur-dialog in, glide; --dur-exit-lg out).
// choices: one decision with commands that differ (Story 10.44's delete sheet) — a radio group of rows, each its label (+ "default"),
// its commands (mono, one per line) and a note; a danger row in --rem. The choice's commands replace the one-command well.
export function ConfirmDialog({ title, children, cmd, choices, value, defaultValue, onChoose, choicesLabel = "Choices", confirmLabel = "Confirm", cancelLabel = "Cancel", tone = "destructive", onConfirm, onCancel, busy = false, closing = false, scrim = true, width = 420 }) {
  const box = React.useRef(null);
  const id = React.useId();
  const destructive = tone === "destructive";
  const [own, setOwn] = React.useState(defaultValue);
  const chosen = value !== undefined ? value : own;
  const choose = (v) => { setOwn(v); onChoose && onChoose(v); };
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
      {choices && (
        <div className="zs-alert-choices" role="radiogroup" aria-label={choicesLabel}>
          {choices.map((c) => (
            <button key={c.id} type="button" role="radio" aria-checked={chosen === c.id}
              className={"zs-alert-choice" + (chosen === c.id ? " is-on" : "") + (c.danger ? " is-danger" : "")} onClick={() => choose(c.id)}>
              <span className={"zs-radio" + (chosen === c.id ? " is-on" : "")} aria-hidden="true"><span className="zs-radio-dot" /></span>
              <span className="zs-alert-choice-t">
                <span className="zs-alert-choice-l">{c.label}{c.id === defaultValue && <span className="zs-alert-default">default</span>}</span>
                <code className="zs-alert-choice-cmd">{c.cmd.join("\n")}</code>
                {c.note && <span className="zs-alert-choice-n">{c.note}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
      {cmd && !choices && <code className="zs-alert-cmd">{cmd}</code>}
      <div className="zs-alert-ft">
        {destructive && <span className="zs-alert-key">⌘↩ confirms</span>}
        <Button size="md" data-k="cancel" onClick={onCancel}>{cancelLabel}</Button>
        <Button size="md" data-k="ok" variant={destructive ? "destructive" : "primary"} busy={busy} onClick={onConfirm} title={destructive ? "⌘↩" : "↩"}>{confirmLabel}</Button>
      </div>
    </div>
  );
  return scrim ? <div className={"zs-scrim" + (closing ? " is-closing" : "")}>{sheet}</div> : sheet;
}
