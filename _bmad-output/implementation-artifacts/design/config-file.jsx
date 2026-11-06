/* global React */
// CONFIG FILE — a page inside each Settings tab (sync #20, Story 11.19): the GUI half of `jj config edit`. Reached from the scope
// line's "Edit…" (General → --user, Project → --repo; the scope's first file, as the CLI picks). The window's height goes to the
// editor; the window is resizable for long lines and long files.
// Editor: monospaced, no wrapping (long lines scroll sideways), line numbers, the file's exact text. Save (gold, ⌘S) checks the text as
// TOML first — the CLI's re-edit loop: a parse error writes nothing, marks the spot (line, column, the span) and shows jj's message;
// you keep editing or Revert (the CLI's "previous config will be restored"). After a save the Settings rows read the file again.
// Unsaved edits ask before Back, another tab or closing the window. A change on disk while you edit shows a notice with Reload.
(() => {
const { useState, useEffect, useRef, useMemo, useLayoutEffect } = React;
const Ic = (p) => <window.Icon {...p}/>;

// ---------- mock files (the app: configFileRead / configFileWrite) ----------
const ident = () => { try { return { name: "Ralph Stein", email: "ralph@dasralph.de", ...JSON.parse(localStorage.getItem("zanshin.settings.general") || "{}") }; } catch { return { name: "Ralph Stein", email: "ralph@dasralph.de" }; } };
const USER = (id) => `[user]
name = "${id.name}"
email = "${id.email}"

[ui]
default-command = "log"
diff-editor = ":builtin"
pager = "less -FRX"

[git]
sign-on-push = true

[signing]
behavior = "drop"
backend = "ssh"
key = "~/.ssh/id_ed25519.pub"

[aliases]
tug = ["bookmark", "move", "--from", "closest_bookmark(@-)", "--to", "@-"]

[revset-aliases]
"closest_bookmark(to)" = "heads(::to & bookmarks())"

[templates]
log_node = '''
coalesce(
  if(!self, label("elided", "~")),
  if(current_working_copy, "@"),
  if(immutable, "◆", "○"),
)
'''
`;
const REPO = `[revset-aliases]
"trunk()" = "main@origin"
"immutable_heads()" = "builtin_immutable_heads() | release/1.5.x@origin"

[git]
fetch = ["origin", "upstream"]
push = "origin"

[remotes.origin]
auto-track-bookmarks = "glob:*"

[user]
email = "ralph@work.example"
`;
const fileKey = (scope, pid) => "zanshin.configfile." + (scope === "user" ? "user" : "repo." + (pid || "_"));
const readFile = (scope, pid) => { try { const s = localStorage.getItem(fileKey(scope, pid)); if (s != null) return s; } catch {} return scope === "user" ? USER(ident()) : REPO; };
const writeFile = (scope, pid, text) => {
  try { localStorage.setItem(fileKey(scope, pid), text); } catch {}
  if (scope === "user") {   // the Identity rows read the file again
    const m = text.match(/(?:^|\n)\[user\]\n([\s\S]*?)(?=\n\[|$)/), sec = m ? m[1] : "";
    const v = (k) => { const m = sec.match(new RegExp("^" + k + '\\s*=\\s*"([^"]*)"', "m")); return m ? m[1] : null; };
    try { const g = JSON.parse(localStorage.getItem("zanshin.settings.general") || "{}"); localStorage.setItem("zanshin.settings.general", JSON.stringify({ ...g, ...(v("name") != null && { name: v("name") }), ...(v("email") != null && { email: v("email") }) })); } catch {}
  }
};
// ?stale (or window.zanshinConfigChangedOnDisk()) — something else writes the file while the page is open
const touch = (scope, pid) => { writeFile(scope, pid, readFile(scope, pid).replace(/^pager = .*$/m, 'pager = "delta"')); window.dispatchEvent(new CustomEvent("zanshin:configfile", { detail: { scope } })); };

// ---------- a mock of jj's check (ConfigLayer::parse → toml_edit): the first error, its message and byte span ----------
function check(text) {
  const lines = text.split("\n");
  let off = 0, depth = 0, ml = null;
  for (let i = 0; i < lines.length; i++) {
    const L = lines[i], s = L.trim(), o = off, at = (col, len, message) => ({ line: i + 1, col: col + 1, start: o + col, end: o + col + Math.max(1, len), message });
    off += L.length + 1;
    if (ml) { if (L.includes(ml)) ml = null; continue; }
    if (depth > 0) { depth += (L.match(/\[/g) || []).length - (L.match(/\]/g) || []).length; continue; }
    if (!s || s.startsWith("#")) continue;
    if (s.startsWith("[")) { if (!/^\[\[?[^\]]+\]\]?\s*(#.*)?$/.test(s)) return at(L.length, 1, "expected `.`, `]`"); continue; }
    const eq = L.indexOf("=");
    if (eq < 0) return at(L.length, 1, "expected `.`, `=`");
    const v = L.slice(eq + 1).trim(), vc = v ? L.indexOf(v, eq) : L.length;
    if (v.startsWith("'''") || v.startsWith('"""')) { const q = v.slice(0, 3); if (v.length < 6 || !v.endsWith(q) || v === q) ml = q; continue; }
    if (v.startsWith('"')) { if (!/^"([^"\\]|\\.)*"\s*(#.*)?$/.test(v)) return at(vc, v.length, "invalid basic string"); continue; }
    if (v.startsWith("'")) { if (!/^'[^']*'\s*(#.*)?$/.test(v)) return at(vc, v.length, "invalid literal string"); continue; }
    if (v.startsWith("[")) { depth = (v.match(/\[/g) || []).length - (v.match(/\]/g) || []).length; continue; }
    if (v.startsWith("{") || /^(true|false|[+-]?\d[\d_]*(\.\d+)?)\s*(#.*)?$/.test(v)) continue;
    return at(vc, v.length || 1, "invalid string\nexpected `\"`, `'`");
  }
  return ml || depth > 0 ? { line: lines.length, col: 1, start: text.length - 1, end: text.length, message: "unexpected end of input" } : null;
}

// ---------- the page ----------
function ConfigFilePage({ scope, project, path, back, onBack, guard }) {
  const pid = project && project.id;
  const [saved, setSaved] = useState(() => readFile(scope, pid));
  const [text, setText] = useState(saved);
  const [err, setErr] = useState(null);
  const [stale, setStale] = useState(false);
  const [flash, setFlash] = useState(false);
  const ta = useRef(null), gut = useRef(null), mir = useRef(null);
  const dirty = text !== saved;
  const lineCount = useMemo(() => text.split("\n").length, [text]);
  const name = path.split("/").pop();

  // the window asks before leaving with unsaved edits (Back, the other tab, closing)
  useEffect(() => { guard.current = dirty ? name : null; return () => { guard.current = null; }; }, [dirty, name]);
  useEffect(() => {
    const h = (e) => { if (e.detail.scope !== scope) return; const now = readFile(scope, pid); if (dirty) setStale(true); else { setSaved(now); setText(now); } };
    window.addEventListener("zanshin:configfile", h);
    return () => window.removeEventListener("zanshin:configfile", h);
  }, [scope, pid, dirty]);
  useEffect(() => { window.zanshinConfigChangedOnDisk = () => touch(scope, pid); if (/[?&]stale\b/.test(location.search)) { const t = setTimeout(() => touch(scope, pid), 2500); return () => clearTimeout(t); } }, [scope, pid]);

  const save = () => {
    if (!dirty) return;
    const e = check(text);
    if (e) { setErr(e); jump(e); return; }
    writeFile(scope, pid, text); setSaved(text); setErr(null); setStale(false);
    setFlash(true); setTimeout(() => setFlash(false), 1600);
  };
  const revert = () => { setText(saved); setErr(null); };
  const reload = () => { const now = readFile(scope, pid); setSaved(now); setText(now); setErr(null); setStale(false); };
  const jump = (e) => { const el = ta.current; if (!el) return; el.focus(); el.setSelectionRange(e.start, e.start); const lh = 19.5; el.scrollTop = Math.max(0, (e.line - 4) * lh); };
  const sync = () => { const el = ta.current; if (gut.current) gut.current.style.transform = `translateY(${-el.scrollTop}px)`; if (mir.current) mir.current.style.transform = `translate(${-el.scrollLeft}px,${-el.scrollTop}px)`; };
  useLayoutEffect(sync, [text, err]);
  const key = (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") { e.preventDefault(); e.stopPropagation(); save(); }
    else if ((e.metaKey || e.ctrlKey) && e.key === "[") { e.preventDefault(); onBack(); }
  };
  const errNow = err;   // stays until the next Save or Revert, like the CLI's message

  return (
    <div className="gcfg-page" onKeyDown={key}>
      <div className="gimp-top"><button className="gimp-back" onClick={onBack} title="Back — ⌘["><Ic name="chevronRight" size={12}/>{back}</button></div>
      <div className="gimp-intro">
        <h2>Config file</h2>
        <p>{scope === "user"
          ? <>jj’s settings for every repository on this Mac, as TOML. The rows in General write here too.</>
          : <>jj’s settings for {project ? project.name : "this project"} only. They win over your user file.</>}</p>
      </div>
      <div className={"gcfg" + (errNow ? " has-err" : "")}>
        <div className="gcfg-bar">
          <code className="gcfg-path" title={path}>{path}</code>
          <span className={"gcfg-state" + (dirty ? " is-dirty" : "")}>{dirty ? "Edited" : flash ? <><Ic name="check" size={11}/>Saved</> : ""}</span>
        </div>
        {stale && (
          <div className="gcfg-note" role="status">
            <Ic name="conflict" size={12}/><span>The file changed on disk while you edited it.</span>
            <button className="rsd-btn gcfg-nbtn" onClick={reload} title="Replaces your edits with the file on disk">Reload</button>
          </div>
        )}
        <div className="gcfg-ed">
          <div className="gcfg-gut" aria-hidden="true"><div ref={gut}>{Array.from({ length: lineCount }, (_, i) => <span key={i} className={errNow && errNow.line === i + 1 ? "is-err" : ""}>{i + 1}</span>)}</div></div>
          <div className="gcfg-text">
            <pre className="gcfg-mirror" aria-hidden="true" ref={mir}>{errNow ? <>{text.slice(0, errNow.start)}<mark>{text.slice(errNow.start, errNow.end) || " "}</mark>{text.slice(errNow.end)}</> : text}{"\n"}</pre>
            <textarea ref={ta} value={text} onChange={e => setText(e.target.value)} onScroll={sync} spellCheck={false} autoCapitalize="off" autoComplete="off" wrap="off" aria-label={"Contents of " + path}/>
          </div>
        </div>
      </div>
      {errNow && (
        <div className="gcfg-err" role="alert">
          <Ic name="conflict" size={12}/>
          <div><b>Not saved: line {errNow.line}, column {errNow.col}</b><span className="gcfg-msg">{errNow.message}</span><span className="gcfg-help">jj only writes a file it can read back. Fix the marked spot, or Revert to the saved file.</span></div>
          <button className="rsd-btn gcfg-nbtn" onClick={() => jump(errNow)}>Show</button>
        </div>
      )}
      <div className="gcfg-ft">
        <span className="gcfg-key">⌘S saves</span>
        <button className="rsd-btn" disabled={!dirty} onClick={revert} title="Back to the saved file">Revert</button>
        <button className="rsd-btn primary" disabled={!dirty} onClick={save} title="⌘S">Save</button>
      </div>
    </div>
  );
}

Object.assign(window, { ConfigFilePage, zanshinConfigCheck: check });
})();
