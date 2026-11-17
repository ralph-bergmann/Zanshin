/* global React, ReactDOM */
// INSPECTOR EXTRAS STUDY (2026-11-17): three design questions in one round.
// 1 · the split button (Story 10.48): the composer's Split ▾ Commit, Squash that runs on a click, where bookmarks land;
// 2 · file masks: hide files you do not care about (generated code) from the inspector's file list;
// 3 · a font and size for code, apart from the app zoom.
(() => {
const { useState, useEffect, useRef } = React;

// ------------------------------------------------------------ icons
const P = {
  check: <path d="M3 8.5l3 3 7-7" stroke="currentColor" strokeWidth="1.8" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  dash: <path d="M4 8h8" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>,
  chev: <path d="M4.5 6.5l3.5 3.5 3.5-3.5" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  close: <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>,
  bookmark: <path d="M4.5 2.5h7v11L8 11l-3.5 2.5v-11z" fill="currentColor"/>,
  filter: <path d="M2.5 3.5h11l-4.3 5v4.5l-2.4-1.3V8.5z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"/>,
  folder: <path d="M2.5 4.5h4l1.5 1.5h5.5v6.5h-11V4.5z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"/>,
  folderOpen: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"><path d="M2.5 12.5v-8h4l1.5 1.5h4.5v1.5"/><path d="M2.5 12.5l1.8-5h10l-1.8 5z"/></g>,
  flat: <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"><path d="M3 4.5h10M3 8h10M3 11.5h10"/></g>,
  tree: <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" fill="none"><path d="M3 3.5h5M5.5 7.5h7.5M5.5 11.5h7.5M3.5 3.5v8h2"/><path d="M3.5 7.5h2"/></g>,
  eyeOff: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinecap="round"><path d="M2 8s2.2-4 6-4 6 4 6 4-2.2 4-6 4-6-4-6-4z"/><circle cx="8" cy="8" r="1.8"/><path d="M3 13L13 3"/></g>,
  at: <g><circle cx="8" cy="8" r="5.5" fill="currentColor" opacity=".25"/><circle cx="8" cy="8" r="2.5" fill="currentColor"/></g>,
};
const Ic = ({ n, s = 14, c }) => <svg className={c} width={s} height={s} viewBox="0 0 16 16" aria-hidden="true">{P[n]}</svg>;

function Check({ state, onToggle, label }) {
  return (
    <button className={"gck" + (state === "all" ? " on" : state === "some" ? " mixed" : "")} role="checkbox"
      aria-checked={state === "all" ? true : state === "some" ? "mixed" : false} aria-label={label} title={label}
      onClick={(e) => { e.stopPropagation(); onToggle(); }}>
      {state === "all" && <Ic n="check" s={10}/>}{state === "some" && <Ic n="dash" s={10}/>}
    </button>
  );
}

// A small toast at the bottom: what a click would run.
let showToast = () => {};
function Toast() {
  const [msg, setMsg] = useState(null);
  useEffect(() => { let t; showToast = (m) => { setMsg(m); clearTimeout(t); t = setTimeout(() => setMsg(null), 2600); }; }, []);
  return msg && <div className="xs-toast" role="status">{msg}</div>;
}

// A menu under its anchor. Rows: {label, cmd, sub, disabled, why, onClick, onHover}.
function Menu({ anchor, rows, onClose }) {
  const ref = useRef(null);
  useEffect(() => {
    const down = (e) => { if (ref.current && !ref.current.contains(e.target) && !anchor.contains(e.target)) onClose(); };
    const key = (e) => { if (e.key === "Escape") onClose(); };
    addEventListener("pointerdown", down, true); addEventListener("keydown", key, true);
    return () => { removeEventListener("pointerdown", down, true); removeEventListener("keydown", key, true); };
  }, [onClose, anchor]);
  const r = anchor.getBoundingClientRect();
  return ReactDOM.createPortal(
    <div ref={ref} className="isd-menu xs-menu" role="menu" style={{ left: r.right, top: r.bottom + 4, transform: "translateX(-100%)" }}
      onMouseLeave={() => rows.forEach((row) => row.onHover && row.onHover(false))}>
      {rows.map((row, i) => (
        <button key={i} role="menuitem" className="isd-menu-row xs-mrow" disabled={row.disabled} title={row.disabled ? row.why : row.cmd}
          onMouseEnter={() => row.onHover && row.onHover(true)} onClick={() => { onClose(); row.onClick && row.onClick(); }}>
          <span className="isd-menu-l">{row.label}</span><span className="isd-menu-h">{row.cmd}</span>
          {row.sub && <span className="xs-msub"><Ic n="bookmark" s={10}/>{row.sub}</span>}
          {row.disabled && row.why && <span className="xs-msub">{row.why}</span>}
        </button>
      ))}
    </div>, document.body);
}

// ------------------------------------------------------------ 1 · the split button
// Label and chevron, divided. The label runs; the chevron opens the alternatives. Each part has its own focus stop,
// hover, pressed and disabled state. `force` pins a state for the gallery.
function SplitButton({ label, primary, small, mainDisabled, why, rows, onRun, force = {} }) {
  const [open, setOpen] = useState(false);
  const chev = useRef(null);
  return (
    <span className={"xs-split" + (primary ? " primary" : "") + (small ? " sm" : "")}>
      <button className={"xs-main" + (force.main ? " is-" + force.main : "")} disabled={mainDisabled} onClick={onRun}
        title={mainDisabled ? why : label}>{label}</button>
      <span className="xs-div"/>
      <button ref={chev} className={"xs-chev" + (force.chev ? " is-" + force.chev : "") + (open ? " is-open" : "")}
        aria-haspopup="menu" aria-expanded={open} aria-label={"More " + label + " actions"} title={"More " + label + " actions"}
        onClick={() => setOpen(!open)}><Ic n="chev" s={12}/></button>
      {open && <Menu anchor={chev.current} rows={rows} onClose={() => setOpen(false)}/>}
    </span>
  );
}

function Gallery() {
  const rows = [
    { label: "Split", cmd: "jj split -r qkynoyuu", onClick: () => showToast("Runs: jj split -r qkynoyuu") },
    { label: "Commit", cmd: "jj commit", onClick: () => showToast("Runs: jj commit") },
  ];
  const sq = [
    { label: "Squash into parent", cmd: "jj squash -r wxkktntx" },
    { label: "Absorb into ancestors", cmd: "jj absorb --from wxkktntx" },
  ];
  const cell = (title, node) => <div className="xs-cell"><div className="xs-cap">{title}</div>{node}</div>;
  return (
    <div className="xs-card xs-gallery">
      <div className="xs-grow">
        <div className="xs-rlabel">Primary · 30</div>
        {cell("rest", <SplitButton primary label="Split" rows={rows} onRun={() => showToast("Runs: jj split")}/>)}
        {cell("hover label", <SplitButton primary label="Split" rows={rows} force={{ main: "hover" }}/>)}
        {cell("hover chevron", <SplitButton primary label="Split" rows={rows} force={{ chev: "hover" }}/>)}
        {cell("focus label", <SplitButton primary label="Split" rows={rows} force={{ main: "focus" }}/>)}
        {cell("focus chevron", <SplitButton primary label="Split" rows={rows} force={{ chev: "focus" }}/>)}
        {cell("pressed", <SplitButton primary label="Split" rows={rows} force={{ main: "press" }}/>)}
      </div>
      <div className="xs-grow">
        <div className="xs-rlabel">Secondary · 30</div>
        {cell("rest", <SplitButton label="Squash" rows={sq} onRun={() => showToast("Runs: jj squash -r wxkktntx")}/>)}
        {cell("hover label", <SplitButton label="Squash" rows={sq} force={{ main: "hover" }}/>)}
        {cell("hover chevron", <SplitButton label="Squash" rows={sq} force={{ chev: "hover" }}/>)}
        {cell("label disabled", <SplitButton label="Squash" rows={sq} mainDisabled why="jj refuses: Cannot squash merge commits without a specified destination"/>)}
        {cell("size 26", <SplitButton small label="Squash" rows={sq}/>)}
      </div>
      <div className="xs-grow">
        <div className="xs-rlabel">Compared</div>
        {cell("button — runs", <button className="gins-btn primary">Commit</button>)}
        {cell("menu button — only opens", <button className="gins-btn isd-menubtn xs-ib" aria-haspopup="menu" title="Diff options"><Ic n="filter" s={13}/><Ic n="chev" s={12}/></button>)}
      </div>
      <p className="xs-rule"><b>Rule.</b> Buttons that look the same work the same. A split button runs its label; only its
        chevron opens the alternatives. A menu button (one part, no divider) only opens a menu — after this story only the
        icon-only diff options. The label always names the command that runs.</p>
    </div>
  );
}

// ------------------------------------------------------------ 2 · the composer
const AT = { id: "qkynoyuu", wc: true, subject: "" };
const OTHER = { id: "wxkktntx", wc: false, subject: "WMMA-505 show error and retry when automations fail to load" };
const FILES = ["lib/src/composer.dart", "lib/src/inspector.dart", "test/composer_test.dart", "pubspec.yaml", "README.md"];

const and = (xs) => xs.length < 3 ? xs.join(" and ") : xs.length + " bookmarks";
const verbs = (change, pick) => {
  if (pick === "none") return { plain: change.wc ? "commit" : "split", disabled: true };
  if (pick === "all") return change.wc ? { plain: "commit" } : { none: true };
  return change.wc ? { main: "split", alt: "commit" } : { plain: "split" };
};
// Where jj puts the change's local bookmarks: jj split moves them to the rest while split.legacy-bookmark-behavior is
// true (jj's default); jj commit leaves them on the change, which keeps the selected part.
const lands = (verb, legacy) => verb === "split" && legacy ? "rest" : "sel";

function Composer({ change, pick, bms, legacy }) {
  const [s, setS] = useState("");
  const [hover, setHover] = useState(null);
  const v = verbs(change, pick);
  const defVerb = v.main || v.plain;
  const verb = hover || defVerb;
  const picked = pick === "part" ? FILES.slice(0, 2) : pick === "all" ? FILES : [];
  const rest = FILES.filter((f) => !picked.includes(f));
  const msg = s.trim();
  const paths = pick === "all" && verb === "commit" ? "" : " " + picked.join(" ");
  const cmdOf = (vb) => (vb === "commit" ? "jj commit" : "jj split -r " + change.id);
  const full = `${cmdOf(verb)} -m '${msg}'${paths}`;
  const where = lands(verb, legacy);
  const chips = (part) => where === part && bms.length > 0 && bms.map((b) => <span key={b} className="xs-bm" title={b + " lands here"}><Ic n="bookmark" s={10}/>{b}</span>);
  const run = (vb) => showToast("Runs: " + `${cmdOf(vb)} -m '${msg}'${pick === "all" && vb === "commit" ? "" : " " + picked.join(" ")}`);
  // A quiet line per row, only when the two verbs put the bookmarks in different places.
  const differ = bms.length > 0 && v.alt && lands(v.main, legacy) !== lands(v.alt, legacy);
  const sub = (vb) => differ ? (lands(vb, legacy) === "rest"
    ? `${and(bms)} ${bms.length === 1 ? "moves" : "move"} to the new working copy`
    : `${and(bms)} ${bms.length === 1 ? "stays" : "stay"} on this change, with the selected part`) : null;
  const row = (vb) => ({ label: vb === "split" ? "Split" : "Commit", cmd: cmdOf(vb), sub: sub(vb), onClick: () => run(vb), onHover: (on) => setHover(on ? vb : null) });
  const Label = { split: "Split", commit: "Commit" };
  return (
    <div className="gcomp xs-comp">
      <div className="gdesc-fields">
        <input className="gdesc-subj" value={s} onChange={(e) => setS(e.target.value)}
          placeholder={verb === "commit" ? "Summary of what you did" : "Summary of the selected changes"}/>
      </div>
      <div className="gcomp-result" aria-label="Result">
        <div className={"gcomp-node is-rest" + (change.wc ? " is-wc" : "")}>
          <span className="gcomp-dot"/>
          {change.wc ? <><span className="gat sm">@</span><span className="gcomp-l">New working copy</span></> : <span className="gcomp-l">Rest</span>}
          {chips("rest")}
          <span className="gcomp-m">{rest.length ? rest.length + (rest.length === 1 ? " file" : " files") : "empty"}</span>
          <span className="gcomp-n">{change.wc ? "stays here to keep working" : <>keeps “{change.subject}”</>}</span>
        </div>
        <div className="gcomp-node is-sel">
          <span className="gcomp-dot"/>
          <span className="gcomp-l">Selected</span>
          {chips("sel")}
          <span className="gcomp-m">{picked.length ? picked.length + (picked.length === 1 ? " file" : " files") : "nothing yet"}</span>
          <span className={"gcomp-n" + (msg ? " is-msg" : "")}>{msg ? <>“{msg}”</> : "no description yet"}</span>
        </div>
      </div>
      <div className="gcomp-ft">
        {!v.none && <code className="isd-cmd" title={full}><span className="v">{cmdOf(verb)} -m '</span><span className="m">{msg}</span><span className="v">'</span><span className="p">{paths}</span></code>}
        {v.none && <span className="xs-flex"/>}
        {!change.wc && <button className="gins-btn">Cancel</button>}
        {v.main && <SplitButton primary label={Label[v.main]} rows={[row(v.main), row(v.alt)]} onRun={() => run(v.main)}/>}
        {v.plain && <button className="gins-btn primary" disabled={v.disabled} onClick={() => run(v.plain)} title={full}>{Label[v.plain]}</button>}
      </div>
      {v.none && <div className="gcomp-hint">Every change is picked — Split needs something left behind. To describe this change, click its title.</div>}
    </div>
  );
}

function Seg({ value, set, opts, label }) {
  return (
    <div className="isd-seg" role="radiogroup" aria-label={label}>
      {opts.map(([k, t]) => <button key={String(k)} className={value === k ? "on" : ""} onClick={() => set(k)}>{t}</button>)}
    </div>
  );
}

function ComposerLab() {
  const [who, setWho] = useState("at");
  const [pick, setPick] = useState("part");
  const [bm, setBm] = useState(true);
  const [legacy, setLegacy] = useState(true);
  const change = who === "at" ? AT : OTHER;
  const v = verbs(change, pick);
  const what = v.none ? "No button: Split needs something left behind (the hint from 10.35)."
    : v.main ? "Split button: a click splits; the chevron offers Commit. Hover a menu row: the preview and the command follow it."
    : v.disabled ? "Disabled: nothing is picked." : `A plain ${v.plain === "split" ? "Split" : "Commit"} — there is no alternative.`;
  return (
    <div className="xs-lab">
      <div className="xs-ctl">
        <label>Change<Seg value={who} set={setWho} label="Change" opts={[["at", "@ working copy"], ["other", "another change"]]}/></label>
        <label>Picked<Seg value={pick} set={setPick} label="Picked" opts={[["part", "2 of 5 files"], ["all", "everything"], ["none", "nothing"]]}/></label>
        <label>Bookmark on the change<Seg value={bm} set={setBm} label="Bookmark" opts={[[true, "feature"], [false, "none"]]}/></label>
        <label><code>split.legacy-bookmark-behavior</code><Seg value={legacy} set={setLegacy} label="legacy bookmark behavior" opts={[[true, "true (jj default)"], [false, "false"]]}/></label>
        <p className="xs-what">{what}</p>
      </div>
      <div className="xs-card xs-insp">
        <div className="xs-ihd"><span className="gat sm">@</span><b>{change.wc ? "Describe this change…" : change.subject}</b></div>
        <div className="xs-fakefiles">
          {FILES.map((f, i) => {
            const on = pick === "all" || (pick === "part" && i < 2);
            return <div key={f} className="xs-ff"><span className={"gck" + (on ? " on" : "")}>{on && <Ic n="check" s={10}/>}</span><span>{f}</span></div>;
          })}
        </div>
        <Composer key={who + pick} change={change} pick={pick} bms={bm ? ["feature"] : []} legacy={legacy}/>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ Squash in the action row
function SquashRow({ merge }) {
  const rows = [
    { label: "Squash into parent", cmd: "jj squash -r wxkktntx", disabled: merge, why: merge ? "Cannot squash merge commits without a specified destination" : null, onClick: () => showToast("Runs: jj squash -r wxkktntx") },
    { label: "Absorb into ancestors", cmd: "jj absorb --from wxkktntx", onClick: () => showToast("Runs: jj absorb --from wxkktntx") },
  ];
  return (
    <div className="xs-act">
      <button className="gins-btn primary"><span className="gat sm">@</span><span>Edit</span></button>
      <SplitButton label="Squash" rows={rows} mainDisabled={merge} why="Cannot squash merge commits without a specified destination"
        onRun={() => showToast("Runs: jj squash -r wxkktntx (the squash form opens first when both changes have a description)")}/>
      <button className="gins-btn danger">Abandon</button>
      {merge && <span className="xs-tip">Squash: Cannot squash merge commits without a specified destination</span>}
    </div>
  );
}

// ------------------------------------------------------------ 4 · file masks
const MASK_FILES = [".claude/skills/create-package/SKILL.md", "app/lib/dependency_registration.dart", "app/lib/routing/app_router.dart",
  "app/lib/routing/app_routes.dart", "app/lib/routing/app_routes.g.dart", "app/lib/screens/buildings/automation_overview_screen.dart",
  "app/pubspec.lock", "app/pubspec.yaml", "docs/packages.dot", "docs/packages.png",
  "packages/design/lib/src/widgets/text_field.dart", "packages/localization/l10n/app_de.arb", "packages/localization/l10n/app_en.arb",
  "packages/localization/lib/src/l10n/core_localizations.dart", "packages/localization/lib/src/l10n/core_localizations_de.dart",
  "packages/localization/lib/src/l10n/core_localizations_en.dart", "packages/logic_designer/lib/src/domain/models/automation.dart",
  "packages/logic_designer/lib/src/domain/models/automation.freezed.dart", "packages/logic_designer/lib/src/domain/models/automation.g.dart",
  "packages/logic_designer/lib/src/presentation/providers/automations_provider.dart",
  "packages/logic_designer/lib/src/presentation/providers/automations_provider.g.dart",
  "packages/logic_designer/lib/src/presentation/widgets/automation_card.dart", "packages/logic_designer/pubspec.yaml", "pubspec.lock"];
// IntelliJ-style masks: * and ? stay inside a name, ** crosses folders; a mask without "/" matches the file name,
// one with "/" the path from the repository root. An entry may hold several masks, comma-separated.
const toRe = (m) => new RegExp("^" + m.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*\/?/g, "\u0000").replace(/\*/g, "[^/]*")
  .replace(/\?/g, "[^/]").replace(/\u0000/g, "(?:.*/)?") + "$");
const matches = (entry, path) => entry.split(",").map((m) => m.trim()).filter(Boolean)
  .some((m) => toRe(m).test(m.includes("/") ? path : path.split("/").pop()));
const fname = (p) => p.split("/").pop();
const dname = (p) => p.slice(0, Math.max(0, p.lastIndexOf("/")));

const buildTree = (files) => {
  const root = { name: "", path: "", dirs: new Map(), files: [] };
  for (const f of files) {
    const seg = f.split("/"); let node = root;
    for (let i = 0; i < seg.length - 1; i++) {
      if (!node.dirs.has(seg[i])) node.dirs.set(seg[i], { name: seg[i], path: seg.slice(0, i + 1).join("/"), dirs: new Map(), files: [] });
      node = node.dirs.get(seg[i]);
    }
    node.files.push(f);
  }
  const join = (d) => { while (!d.files.length && d.dirs.size === 1) { const c = [...d.dirs.values()][0]; d = { ...c, name: d.name + "/" + c.name }; } d.dirs = new Map([...d.dirs].map(([k, v]) => [k, join(v)])); return d; };
  root.dirs = new Map([...root.dirs].map(([k, v]) => [k, join(v)]));
  return root;
};
const filesUnder = (d) => [...d.files, ...[...d.dirs.values()].flatMap(filesUnder)];
const treeRows = (root) => {
  const out = [];
  const walk = (d, depth) => {
    for (const c of d.dirs.values()) { out.push({ kind: "dir", path: c.path, name: c.name, depth, files: filesUnder(c) }); walk(c, depth + 1); }
    for (const f of d.files) out.push({ kind: "file", path: f, depth });
  };
  walk(root, 0);
  return out;
};

function MaskPopover({ masks, setMasks, anchor, onClose, counts }) {
  const ref = useRef(null);
  const [text, setText] = useState("");
  useEffect(() => {
    const down = (e) => { if (ref.current && !ref.current.contains(e.target) && !anchor.contains(e.target)) onClose(); };
    const key = (e) => { if (e.key === "Escape") onClose(); };
    addEventListener("pointerdown", down, true); addEventListener("keydown", key, true);
    return () => { removeEventListener("pointerdown", down, true); removeEventListener("keydown", key, true); };
  }, [onClose, anchor]);
  const r = anchor.getBoundingClientRect();
  const add = () => {
    const m = text.trim();
    if (!m) return;
    setMasks((ms) => [{ m, on: true }, ...ms.filter((x) => x.m !== m)]);
    setText("");
  };
  return ReactDOM.createPortal(
    <div ref={ref} className="isd-menu xs-pop" role="dialog" aria-label="Hide files" style={{ left: r.left, top: r.bottom + 6 }}>
      <div className="xs-pophd">Hide files matching</div>
      <input className="gset-in xs-maskin" autoFocus value={text} onChange={(e) => setText(e.target.value)} spellCheck={false}
        onKeyDown={(e) => { if (e.key === "Enter") add(); }} placeholder="Add a mask, e.g. *.g.dart  ↵" aria-label="New file mask"/>
      <div className="xs-masks">
        {masks.map((x, i) => (
          <div key={x.m} className="xs-mask" onClick={() => setMasks((ms) => ms.map((y, j) => j === i ? { ...y, on: !y.on } : y))}>
            <Check state={x.on ? "all" : "none"} onToggle={() => setMasks((ms) => ms.map((y, j) => j === i ? { ...y, on: !y.on } : y))} label={(x.on ? "Stop hiding " : "Hide ") + x.m}/>
            <code>{x.m}</code>
            <span className="xs-mcount">{counts[x.m] || ""}</span>
            <button className="xs-mdel" title="Remove from the list" aria-label={"Remove " + x.m}
              onClick={(e) => { e.stopPropagation(); setMasks((ms) => ms.filter((_, j) => j !== i)); }}><Ic n="close" s={11}/></button>
          </div>
        ))}
      </div>
      <div className="xs-popft">* and ? match inside a name, ** across folders. A mask with “/” matches the path. Separate several with commas.</div>
    </div>, document.body);
}

function MaskedFiles() {
  const [masks, setMasks] = useState([
    { m: "*.g.dart, *.freezed.dart", on: true },
    { m: "core_localizations*.dart", on: true },
    { m: "*.lock", on: false },
    { m: "docs/*.png", on: false },
  ]);
  const [pop, setPop] = useState(false);
  const [peek, setPeek] = useState(false);
  const [view, setView] = useState("tree");
  const [picks, setPicks] = useState(() => new Set(MASK_FILES));
  const btn = useRef(null);
  const active = masks.filter((x) => x.on);
  const hidden = MASK_FILES.filter((f) => active.some((x) => matches(x.m, f)));
  const counts = Object.fromEntries(masks.map((x) => [x.m, MASK_FILES.filter((f) => matches(x.m, f)).length]));
  const shown = peek ? MASK_FILES : MASK_FILES.filter((f) => !hidden.includes(f));
  const st = (fs) => { const k = fs.filter((f) => picks.has(f)).length; return !k ? "none" : k === fs.length ? "all" : "some"; };
  const toggle = (fs) => setPicks((p) => { const n = new Set(p), on = !fs.every((f) => p.has(f)); fs.forEach((f) => on ? n.add(f) : n.delete(f)); return n; });
  const rows = view === "tree" ? treeRows(buildTree(shown)) : shown.map((f) => ({ kind: "file", path: f, depth: 0 }));
  return (
    <div className="xs-card cs-files xs-mfiles">
      <div className="cs-fhd">
        <span className="cs-gut"><Check state={st(MASK_FILES)} onToggle={() => toggle(MASK_FILES)} label="Pick all, hidden files included"/></span>
        <span className="cs-ftitle">Changes</span>
        <span className="cs-fmeta">{MASK_FILES.length} files</span>
        <button ref={btn} className={"xs-fbtn" + (active.length ? " is-on" : "") + (pop ? " is-open" : "")} onClick={() => setPop(!pop)}
          aria-haspopup="dialog" title={active.length ? `Hiding files matching ${active.length} ${active.length === 1 ? "mask" : "masks"}` : "Hide files by name"}>
          <Ic n="filter" s={13}/>{active.length > 0 && <span>{active.length}</span>}
        </button>
        <div className="isd-seg cs-fview" role="radiogroup" aria-label="File list">
          <button className={view !== "tree" ? "on" : ""} onClick={() => setView("flat")} title="Flat list"><Ic n="flat" s={13}/></button>
          <button className={view === "tree" ? "on" : ""} onClick={() => setView("tree")} title="Tree"><Ic n="tree" s={13}/></button>
        </div>
      </div>
      <div className="cs-flist">
        {rows.map((r) => {
          if (r.kind === "dir") return (
            <div key={"d" + r.path} className="cs-row is-dir" title={r.path}>
              <span className="cs-gut"><Check state={st(r.files)} onToggle={() => toggle(r.files)} label={"Pick " + r.name}/></span>
              <span className="cs-ind" style={{ paddingLeft: r.depth * 14 }}><span className="cs-ficon"><Ic n="folderOpen" s={14}/></span>{r.name}</span>
            </div>);
          const masked = hidden.includes(r.path);
          return (
            <div key={"f" + r.path} className={"cs-row" + (masked ? " xs-masked" : "")} title={masked ? r.path + " · hidden by a file mask" : r.path}>
              <span className="cs-gut"><Check state={st([r.path])} onToggle={() => toggle([r.path])} label={"Pick " + fname(r.path)}/></span>
              <span className="cs-ind" style={view === "tree" ? { paddingLeft: r.depth * 14 + 20 } : undefined}>
                <span className="cs-name">{fname(r.path)}</span>
                {masked && <Ic n="eyeOff" s={12} c="xs-meye"/>}
                {view !== "tree" && <span className="cs-dir">{dname(r.path)}</span>}
              </span>
            </div>);
        })}
      </div>
      {hidden.length > 0 && (
        <div className="xs-hidden">
          <span className="cs-gut"><Check state={st(hidden)} onToggle={() => toggle(hidden)} label={`Pick the ${hidden.length} hidden files`}/></span>
          <span className="xs-htxt">{peek ? `${hidden.length} files match your masks` : `${hidden.length} files hidden`}
            {st(hidden) === "all" ? " · all picked" : st(hidden) === "some" ? " · some picked" : " · none picked"}</span>
          <button className="cs-gall xs-hbtn" onClick={() => setPeek(!peek)}>{peek ? "Hide" : "Show"}</button>
          <button className="cs-gall xs-hbtn" onClick={() => setPop(true)}>Masks…</button>
        </div>
      )}
      {pop && <MaskPopover masks={masks} setMasks={setMasks} anchor={btn.current} onClose={() => setPop(false)} counts={counts}/>}
    </div>
  );
}

// ------------------------------------------------------------ 5 · code font and size
const FONTS = [
  ["JetBrains Mono", "JetBrains Mono · built in"], ["SF Mono", "SF Mono"], ["Menlo", "Menlo"], ["Monaco", "Monaco"],
  ["Monaspace Argon", "Monaspace Argon"], ["Courier New", "Courier New"],
];
const SIZES = [9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24];
const SAMPLE = [
  [" ", 64, 64, "  @override"],
  [" ", 65, 65, "  Widget build(BuildContext context) {"],
  [" ", 66, 66, "    final s = context.strings;"],
  ["-", 67, null, "    final automations = ref.watch(automationsProvider).value;"],
  ["+", null, 67, "    final automationsState = ref.watch(automationsProvider);"],
  [" ", 68, 68, ""],
  [" ", 69, 69, "    return Scaffold("],
  ["-", 70, null, "      body: automations == null ? const Spinner() : _list(automations),"],
  ["+", null, 70, "      body: _buildBody(context, automationsState),"],
  [" ", 71, 71, "    );"],
];
function CodeFont() {
  const [font, setFont] = useState("JetBrains Mono");
  const [size, setSize] = useState(11);
  const [zoom, setZoom] = useState(100);
  const px = size * zoom / 100;
  return (
    <div className="xs-fontlab">
      <div className="xs-card gset-grp xs-set">
        <h3>Diff</h3>
        <div className="xs-setbox">
          <div className="gset-row"><div className="gset-lbl"><span>Layout</span></div><div className="gset-ctl"><span className="xs-dim">Unified · Side by side</span></div></div>
          <div className="gset-row">
            <div className="gset-lbl"><span>Code font</span><span className="gset-hint">The monospaced fonts on this Mac.</span></div>
            <div className="gset-ctl"><select className="gset-sel" value={font} onChange={(e) => setFont(e.target.value)} aria-label="Code font">
              {FONTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
          </div>
          <div className="gset-row">
            <div className="gset-lbl"><span>Code size</span><span className="gset-hint">Diffs and the config file. Zoom scales it like everything else.</span></div>
            <div className="gset-ctl"><select className="gset-sel xs-size" value={size} onChange={(e) => setSize(+e.target.value)} aria-label="Code size">
              {SIZES.map((n) => <option key={n} value={n}>{n === 11 ? "11 pt · default" : n + " pt"}</option>)}</select></div>
          </div>
          <div className="gset-row"><div className="gset-lbl"><span>Changed words</span></div><div className="gset-ctl"><span className="xs-dim">on</span></div></div>
        </div>
        <div className="xs-zoom">Pretend the app zoom is
          <Seg value={zoom} set={setZoom} label="Zoom" opts={[[90, "90%"], [100, "100%"], [125, "125%"]]}/>
          <span className="xs-dim">→ {+px.toFixed(1)} px on screen</span></div>
      </div>
      <div className="isd-diff xs-sample" style={{ "--code-font": `"${font}", "JetBrains Mono", monospace`, "--code-size": px + "px" }}>
        <div className="isd-dbar"><span className="isd-dpath"><span className="isd-dname">automation_overview_page.dart</span></span></div>
        <div className="isd-dbody"><div className="isd-dcontent is-wide">
          {SAMPLE.map(([k, o, n, s], i) => (
            <div key={i} className={"isd-line k" + (k === "+" ? "a" : k === "-" ? "r" : "c")}>
              <span className="isd-nums"><span>{o ?? ""}</span><span>{n ?? ""}</span></span>
              <span className="isd-sig">{k === "+" ? "+" : k === "-" ? "−" : ""}</span><span className="isd-txt">{s}</span>
            </div>))}
        </div></div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ page
function App() {
  const [theme, setTheme] = useState("dark");
  useEffect(() => { document.documentElement.dataset.theme = theme; }, [theme]);
  return (
    <div className="xs-win">
      <header className="xs-head">
        <div><b>Inspector Extras Study</b> — three questions in one round: the split button (Story 10.48), file masks for
          the file list, and a font and size for code.</div>
        <Seg value={theme} set={setTheme} label="Theme" opts={[["dark", "Night"], ["light", "Paper"]]}/>
      </header>

      <section>
        <h2>1 · Split button <span className="xs-tag">DS · components/actions</span></h2>
        <p className="xs-note">A new component beside Button and MenuButton: the label runs, the divided chevron opens the alternatives.
          Tab stops on each part; VoiceOver reads the chevron as “More Split actions”. Click the chevrons.</p>
        <Gallery/>
      </section>

      <section>
        <h2>2 · Composer — the verb follows the pick</h2>
        <p className="xs-note">Change the scenario on the left. The bookmark chip in the preview sits on the part where the click puts it;
          the menu rows say it in a quiet line, only when the two rows differ.</p>
        <ComposerLab/>
      </section>

      <section>
        <h2>3 · Squash runs on a click</h2>
        <p className="xs-note">The label squashes into the parent (the squash form first when both changes have a description);
          the chevron keeps both rows. On a merge only the label is off — Absorb still runs.</p>
        <div className="xs-card xs-acts"><SquashRow/><SquashRow merge/></div>
      </section>

      <section>
        <h2>4 · File masks — hide files you do not care about</h2>
        <p className="xs-note">The funnel in the file list's header opens the list: tick the masks to use, type a new one and press ↵.
          Hidden files stay part of the change — a commit or split still takes them as picked; the row at the bottom says how many and
          lets you pick them, show them, or edit the masks. Try <code>*.arb</code>.</p>
        <MaskedFiles/>
      </section>

      <section>
        <h2>5 · Code font and size</h2>
        <p className="xs-note">Settings › Diff gets two rows. The size is in points, not a second zoom; the app zoom multiplies it.
          The preview uses the fonts installed on this Mac.</p>
        <CodeFont/>
      </section>

      <section className="xs-open">
        <h2>Open questions</h2>
        <ol>
          <li><b>Masks: app-wide or per project?</b> Proposal: one list for the app (Settings › Diff, like here), ticks too — generated
            files look alike across projects.</li>
          <li><b>Masks in the graph?</b> Proposal: no — only the inspector's file list and its diff. The card's file count stays the truth.</li>
          <li><b>Code size for ids and bookmarks?</b> Proposal: no — only code blocks (diffs, the config file). Ids stay with the UI.</li>
          <li><b>Shortcut for the code size?</b> Proposal: none for now; ⌘+ / ⌘− stay the app zoom.</li>
        </ol>
      </section>
      <Toast/>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
})();
