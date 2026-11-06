import React from "react";
import { SettingsPage } from "./SettingsPage.jsx";
import { Icon } from "../brand/Icon.jsx";
import { Button } from "../actions/Button.jsx";

// ConfigFilePage — the GUI half of `jj config edit` (sync #20): a page inside each Settings tab, reached from the scope line's "Edit…"
// (General → --user, Project → --repo; the scope's first file, as the CLI picks). It takes the window's height; the window is resizable.
// The editor: the file's exact text, monospaced, line numbers, no wrapping (long lines scroll sideways). Save (gold, ⌘S) — jj checks the
// text as TOML first (the CLI's re-edit loop): an error writes nothing, marks its span (gutter line + wavy underline), names line and column
// and shows jj's message; you keep editing or Revert (the CLI's "previous config will be restored"). After a save Settings reads the file
// again. Unsaved edits ask before Back, another tab or closing (onDirtyChange — the window asks with a ConfirmDialog). stale: the file
// changed on disk while you edited — a notice with Reload. onSave(text) returns null or { error: { message, start, end } } (text offsets).
function zsCfgPos(text, at) {
  const before = text.slice(0, at).split("\n");
  return { line: before.length, col: before[before.length - 1].length + 1 };
}

export function ConfigFilePage({ scope = "user", path, text = "", back, project, onBack, onSave, onReload, onDirtyChange, stale = false,
  initialDraft, initialError = null, className = "" }) {
  const [draft, setDraft] = React.useState(initialDraft != null ? initialDraft : text);
  const [error, setError] = React.useState(initialError);
  const [saved, setSaved] = React.useState(false);
  const ta = React.useRef(null), gut = React.useRef(null), mir = React.useRef(null);
  // a new saved text (a save, Reload) replaces the draft; the first render keeps initialDraft
  const mounted = React.useRef(false);
  React.useEffect(() => { if (mounted.current) { setDraft(text); setError(null); } mounted.current = true; }, [text]);
  const dirty = draft !== text;
  React.useEffect(() => { if (onDirtyChange) onDirtyChange(dirty); }, [dirty]);
  const lines = draft.split("\n").length;
  const pos = error ? zsCfgPos(draft, error.start) : null;
  const sync = () => {
    const el = ta.current; if (!el) return;
    if (gut.current) gut.current.style.transform = "translateY(" + -el.scrollTop + "px)";
    if (mir.current) mir.current.style.transform = "translate(" + -el.scrollLeft + "px," + -el.scrollTop + "px)";
  };
  React.useLayoutEffect(sync, [draft, error]);
  const show = (e) => { const el = ta.current; if (!el || !e) return; el.focus(); el.setSelectionRange(e.start, e.start); };
  const save = () => {
    if (!dirty) return;
    const res = onSave ? onSave(draft) : null;
    if (res && res.error) { setError(res.error); show(res.error); return; }
    setError(null); setSaved(true); setTimeout(() => setSaved(false), 1600);
  };
  const onKey = (e) => { if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") { e.preventDefault(); e.stopPropagation(); save(); } };
  return (
    <SettingsPage className={("zs-cfg-page " + className).trim()} back={back} onBack={onBack} title="Config file"
      intro={scope === "user" ? "jj’s settings for every repository on this Mac, as TOML. The rows in General write here too."
        : "jj’s settings for " + (project || "this project") + " only. They win over your user file."}>
      <div className={"zs-cfg" + (error ? " has-error" : "")} onKeyDown={onKey}>
        <div className="zs-cfg-bar">
          <code className="zs-cfg-path" title={path}>{path}</code>
          <span className={"zs-cfg-state" + (dirty ? " is-dirty" : "")}>{dirty ? "Edited" : saved ? <><Icon name="check" size="xs" />Saved</> : null}</span>
        </div>
        {stale && (
          <div className="zs-cfg-note" role="status">
            <Icon name="conflict" size="sm" /><span>The file changed on disk while you edited it.</span>
            <Button size="sm" onClick={onReload} title="Replaces your edits with the file on disk">Reload</Button>
          </div>
        )}
        <div className="zs-cfg-ed">
          <div className="zs-cfg-gut" aria-hidden="true"><div ref={gut}>{Array.from({ length: lines }, (_, i) => <span key={i} className={pos && pos.line === i + 1 ? "is-error" : undefined}>{i + 1}</span>)}</div></div>
          <div className="zs-cfg-text">
            <pre className="zs-cfg-mirror" aria-hidden="true" ref={mir}>{error ? <>{draft.slice(0, error.start)}<mark>{draft.slice(error.start, error.end) || " "}</mark>{draft.slice(error.end)}</> : draft}{"\n"}</pre>
            <textarea ref={ta} value={draft} onChange={(e) => setDraft(e.target.value)} onScroll={sync} wrap="off" spellCheck={false} autoCapitalize="off" autoComplete="off" aria-label={"Contents of " + path} />
          </div>
        </div>
      </div>
      {error && (
        <div className="zs-cfg-err" role="alert">
          <Icon name="conflict" size="sm" />
          <div><b>Not saved: line {pos.line}, column {pos.col}</b><span className="zs-cfg-msg">{error.message}</span>
            <span className="zs-cfg-help">jj only writes a file it can read back. Fix the marked spot, or Revert to the saved file.</span></div>
          <Button size="sm" onClick={() => show(error)}>Show</Button>
        </div>
      )}
      <div className="zs-cfg-ft">
        <span className="zs-cfg-key">⌘S saves</span>
        <Button size="md" disabled={!dirty} onClick={() => { setDraft(text); setError(null); }} title="Back to the saved file">Revert</Button>
        <Button size="md" variant="primary" disabled={!dirty} onClick={save} title="⌘S">Save</Button>
      </div>
    </SettingsPage>
  );
}
ConfigFilePage.position = zsCfgPos;
