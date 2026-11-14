/* global React, ReactDOM */
// INSPECTOR STUDY — the design round for Stories 10.35, 10.36, 10.38 and 10.39 (2026-11-14).
// A self-contained mock of the floating inspector: files beside or above the diff by width, a draggable divider,
// name-first file rows, tree or flat, Finder keys, context menus (copy, Reveal in Finder, Open in Editor), the Squash
// menu with jj absorb, parent ids with a jump, the composer's command cut in its message.
(() => {
const { useState, useEffect, useLayoutEffect, useMemo, useRef, useCallback } = React;

// ------------------------------------------------------------ store (per viewer, best effort)
const KEY = "zanshin.inspStudy.";
const load = (k, d) => { try { const v = localStorage.getItem(KEY + k); return v == null ? d : JSON.parse(v); } catch { return d; } };
const save = (k, v) => { try { localStorage.setItem(KEY + k, JSON.stringify(v)); } catch { /* storage off */ } };
const useStored = (k, d) => { const [v, setV] = useState(() => load(k, d)); useEffect(() => save(k, v), [k, v]); return [v, setV]; };

// ------------------------------------------------------------ icons
const P = {
  close: <path d="M3.5 3.5l9 9M12.5 3.5l-9 9" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>,
  check: <path d="M3 8.5l3 3 7-7" stroke="currentColor" strokeWidth="1.8" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  dash: <path d="M4 8h8" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>,
  chevronDown: <path d="M4.5 6.5l3.5 3.5 3.5-3.5" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  chevronRight: <path d="M6 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  folder: <path d="M2.5 4.5h4l1.5 1.5h5.5v6.5h-11V4.5z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"/>,
  flat: <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"><path d="M3 4.5h10M3 8h10M3 11.5h10"/></g>,
  tree: <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" fill="none"><path d="M3 3.5h5M5.5 7.5h7.5M5.5 11.5h7.5M3.5 3.5v8h2"/><path d="M3.5 7.5h2"/></g>,
  parent: <g stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 2.5v7M5 6.8L8 9.8l3-3"/><circle cx="8" cy="13" r="1.6"/></g>,
  plus: <path d="M8 3v10M3 8h10" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>,
  unified: <g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="2" y="3" width="12" height="10" rx="1.2"/><path d="M2 8h12"/></g>,
  side: <g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="2" y="3" width="12" height="10" rx="1.2"/><path d="M8 3v10"/></g>,
  bookmark: <path d="M4.5 2.5h7v11L8 11l-3.5 2.5v-11z" fill="currentColor"/>,
  tune: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M2.5 4.5h6M11.5 4.5h2M2.5 11.5h2M7.5 11.5h6"/><circle cx="10" cy="4.5" r="1.6"/><circle cx="6" cy="11.5" r="1.6"/></g>,
  ws: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M2.5 11.5v1.5h11v-1.5"/><circle cx="5" cy="6.5" r=".9" fill="currentColor" stroke="none"/><circle cx="8" cy="6.5" r=".9" fill="currentColor" stroke="none"/><circle cx="11" cy="6.5" r=".9" fill="currentColor" stroke="none"/></g>,
  pen: <path d="M3 13l.6-2.6L10.5 3.5l2 2-6.9 6.9L3 13zM9.3 4.7l2 2" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round"/>,
};
const Ic = ({ n, s = 14, c }) => <svg className={c} width={s} height={s} viewBox="0 0 16 16" aria-hidden="true">{P[n]}</svg>;

// ------------------------------------------------------------ data
const REPO = "/Users/you/dev/TWMS-Flutter-App/";
const F = (path, status, a, r) => ({ path, status, a, r });
const CHANGES = {
  qkynoyuu: { id: "qkynoyuuwpsz", prefix: 1, commit: "6d087245", cprefix: 1, wc: true, mutable: true, subject: "", description: "",
    author: "Ralph Bergmann", date: "2d", parents: ["uyoxptom"], bookmarks: [], absorbReason: "Nothing to absorb: no hunk belongs to an earlier change.",
    files: [F("app/ios/Podfile.lock", "M", 2, 2), F("pubspec.lock", "M", 8, 8)] },
  wxkktntx: { id: "wxkktntxsrqm", prefix: 1, commit: "5c45503a", cprefix: 1, mutable: true,
    subject: "WMMA-505 show error and retry when automations fail to load",
    description: "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>", author: "Ralph Bergmann", date: "3d",
    parents: ["vzttmozo"], bookmarks: ["WMMA-505_wizard_shell_for_logic_designer"],
    files: [F("packages/design/lib/src/constants/semantics_identifiers.dart", "M", 1, 0),
      F("packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart", "M", 54, 26),
      F("packages/logic_designer/pubspec.yaml", "M", 1, 0),
      F("packages/logic_designer/test/presentation/widgets/automation_overview_page_test.dart", "A", 136, 0)] },
  vzttmozo: { id: "vzttmozoklne", prefix: 2, commit: "a91c03fe", cprefix: 1, mutable: true, subject: "WMMA-505 use short save label in the wizard",
    description: "", author: "Ralph Bergmann", date: "3d", parents: ["zlyklnxo"], bookmarks: [],
    files: [F("packages/localization/l10n/app_en.arb", "M", 1, 1), F("packages/localization/l10n/app_de.arb", "M", 1, 1)] },
  rqxsqwnr: { id: "rqxsqwnrtpvo", prefix: 1, commit: "9ee306df", cprefix: 3, immutable: true,
    subject: "WMMA-591 add automation overview, detail and function wizard shell",
    description: "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>\n\nremove detail page\n\nThe detail page moved into the wizard: the overview opens the wizard directly, and the wizard's first step shows what the detail page showed.\n\nAlso: the routes were regenerated, the localizations gained the wizard's strings, and the design package got a dropdown and a text field that the wizard needs.",
    author: "Ralph Bergmann", date: "3d", parents: ["srxssrkv"], bookmarks: [],
    files: [F(".claude/skills/create-package/SKILL.md", "M", 5, 1), F("app/lib/dependency_registration.dart", "M", 2, 0),
      F("app/lib/routing/app_router.dart", "M", 2, 0), F("app/lib/routing/app_routes.dart", "M", 41, 0), F("app/lib/routing/app_routes.g.dart", "M", 73, 0),
      F("app/lib/screens/buildings/automation_overview_screen.dart", "A", 9, 0), F("app/lib/screens/buildings/controller_distribution_screen.dart", "M", 2, 0),
      F("app/pubspec.yaml", "M", 1, 0), F("docs/ARCHITECTURE.md", "M", 1, 0), F("docs/packages.dot", "M", 3, 1), F("docs/packages.png", "M", 0, 0),
      F("packages/design/lib/src/constants/semantics_identifiers.dart", "M", 22, 0), F("packages/design/lib/src/widgets/dropdown_menu.dart", "M", 5, 0),
      F("packages/design/lib/src/widgets/text_field.dart", "M", 34, 27), F("packages/localization/l10n/app_de.arb", "M", 25, 0),
      F("packages/localization/l10n/app_en.arb", "M", 11, 0), F("packages/localization/lib/src/l10n/core_localizations.dart", "M", 66, 0),
      F("packages/localization/lib/src/l10n/core_localizations_de.dart", "M", 43, 0), F("packages/localization/lib/src/l10n/core_localizations_en.dart", "M", 43, 0),
      F("packages/logic_designer/lib/logic_designer.dart", "A", 4, 0), F("packages/logic_designer/lib/src/data/repositories/mock_automation_repository.dart", "A", 37, 0),
      F("packages/logic_designer/lib/src/di.dart", "A", 10, 0), F("packages/logic_designer/lib/src/domain/models/automation.dart", "A", 43, 0),
      F("packages/logic_designer/lib/src/domain/models/automation.freezed.dart", "A", 864, 0), F("packages/logic_designer/lib/src/domain/repositories/automation_repository.dart", "A", 5, 0),
      F("packages/logic_designer/lib/src/domain/use_cases/get_automations_use_case.dart", "A", 10, 0), F("packages/logic_designer/lib/src/presentation/providers/automations_provider.dart", "A", 9, 0),
      F("packages/logic_designer/lib/src/presentation/providers/automations_provider.g.dart", "A", 49, 0), F("packages/logic_designer/lib/src/presentation/widgets/automation_card.dart", "A", 99, 0),
      F("packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart", "A", 62, 0), F("packages/logic_designer/lib/src/presentation/widgets/automation_status_badge.dart", "A", 19, 0),
      F("packages/logic_designer/lib/src/presentation/widgets/dialog_helpers.dart", "A", 35, 0), F("packages/logic_designer/pubspec.yaml", "A", 34, 0),
      F("packages/shared/lib/src/routing/app_route_paths.dart", "M", 2, 0),
      F("packages/topology/lib/src/presentation/widgets/controller_distribution/controller_distribution_view.dart", "M", 3, 0),
      F("packages/topology/lib/src/presentation/widgets/controller_distribution/topics_section.dart", "M", 17, 10)] },
};
const ORDER = ["qkynoyuu", "wxkktntx", "vzttmozo", "rqxsqwnr"];
const short = (id, prefix) => id.slice(0, Math.max(prefix, 8));
const fname = (p) => p.split("/").pop();
const dname = (p) => { const i = p.lastIndexOf("/"); return i < 0 ? "" : p.slice(0, i); };

// deterministic diff lines for a file
const CODE = [
  (n) => `import 'package:${n}/src/presentation/widgets/automation_overview_page.dart';`,
  (n) => `  static const automationOverview_retry = 'automationOverview_retry';`,
  (n) => `    final automations = ref.watch(automationsProvider);`,
  (n) => `    return automations.when(data: (items) => _List(items: items), error: (e, _) => _Error(onRetry: () => ref.invalidate(automationsProvider)), loading: _Loading.new);`,
  (n) => `  Widget build(BuildContext context, WidgetRef ref) {`,
  (n) => `      padding: const EdgeInsets.symmetric(horizontal: Spacing.spacing16, vertical: Spacing.spacing8),`,
  (n) => `      child: Text(s.automationOverview_title, style: theme.textTheme.titleMedium),`,
  (n) => `  }`,
  (n) => `    expect(find.bySemanticsIdentifier(SemanticsIdentifiers.automationOverview_retry), findsOneWidget);`,
  (n) => `  const ${n.replace(/[^a-z]/gi, "")}({super.key});`,
];
const hash = (s) => { let h = 2166136261; for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619); return h >>> 0; };
// A hunk holds one or more sections (jj's builtin diff editor sections: the changed runs between unchanged lines);
// context 3 joins runs that are at most 6 lines apart into one hunk. A section is what can be picked.
const HUNKS = new Map();
const hunksOf = (f) => {
  if (HUNKS.has(f.path)) return HUNKS.get(f.path);
  let seed = hash(f.path);
  const rnd = () => (seed = Math.imul(seed ^ (seed >>> 15), 2246822507) >>> 0) / 4294967296;
  const line = () => CODE[Math.floor(rnd() * CODE.length)](fname(f.path).replace(/\.\w+$/, ""));
  const A = Math.min(f.a, 30), R = Math.min(f.r, 14), hs = [];
  if (!A && !R) { HUNKS.set(f.path, hs); return hs; }
  if (f.status === "A") {
    const id = f.path + "#0";
    hs.push({ id, oldStart: 0, newStart: 1, ctx: "", sections: [id + "/0"], lines: Array.from({ length: A }, () => ({ k: "+", s: line(), sec: id + "/0" })) });
    HUNKS.set(f.path, hs); return hs;
  }
  const n = A + R > 12 ? 2 : 1;
  let o = 12 + Math.floor(rnd() * 20), d = 0;
  for (let h = 0; h < n; h++) {
    const a = h === n - 1 ? A - Math.floor(A / n) * (n - 1) : Math.floor(A / n), r = h === n - 1 ? R - Math.floor(R / n) * (n - 1) : Math.floor(R / n);
    const id = f.path + "#" + h, lines = [], sections = [];
    const groups = Math.max(1, Math.min(3, Math.floor((a + r) / 3)));
    for (let i = 0; i < 3; i++) lines.push({ k: " ", s: line() });
    for (let g = 0; g < groups; g++) {
      const sec = id + "/" + g;
      sections.push(sec);
      const gr = g === groups - 1 ? r - Math.floor(r / groups) * (groups - 1) : Math.floor(r / groups);
      const ga = g === groups - 1 ? a - Math.floor(a / groups) * (groups - 1) : Math.floor(a / groups);
      for (let i = 0; i < gr; i++) lines.push({ k: "-", s: line(), sec });
      for (let i = 0; i < ga; i++) lines.push({ k: "+", s: line(), sec });
      if (g === 0 && h === 0 && r > 0) {
        // a section that changes code and also re-indents a line
        const s = line().trim();
        lines.push({ k: "-", s: "    " + s, sec, ws: true }, { k: "+", s: "        " + s, sec, ws: true });
      }
      for (let i = 0, gap = g === groups - 1 ? 3 : 2 + Math.floor(rnd() * 4); i < gap; i++) lines.push({ k: " ", s: line() });
      if (g === 0 && h === 0 && r > 0) {
        // a line that only changed its indentation: its own section, gone while whitespace is ignored
        const sec2 = id + "/ws", s = line().trim();
        sections.push(sec2);
        lines.push({ k: "-", s: "  " + s, sec: sec2, ws: true }, { k: "+", s: "      " + s, sec: sec2, ws: true });
        for (let i = 0; i < 2; i++) lines.push({ k: " ", s: line() });
      }
    }
    hs.push({ id, oldStart: o, newStart: o + d, ctx: h ? "class _AutomationOverviewState" : "abstract final class SemanticsIdentifiers {", sections, lines });
    d += lines.filter(l => l.k === "+").length - lines.filter(l => l.k === "-").length;
    o += 40 + Math.floor(rnd() * 60);
  }
  HUNKS.set(f.path, hs);
  return hs;
};
const sectionsOf = (fs) => fs.flatMap(f => hunksOf(f).flatMap(h => h.sections));
// What a hunk shows. With whitespace ignored, an indentation-only line reads as unchanged — unless its section is
// picked (or opened): then it shows, dimmed, so a pick never takes a line you did not see. A section made only of
// such lines folds into one row with its own checkbox.
const shown = (h, ws, picks, open) => {
  if (ws === "show") return h;
  const out = [];
  const wsOnly = new Set(h.sections.filter(s => h.lines.filter(l => l.sec === s).every(l => l.ws)));
  for (let i = 0; i < h.lines.length; i++) {
    const l = h.lines[i];
    if (!l.ws) { out.push(l); continue; }
    if (picks.has(l.sec) || open.has(l.sec)) { out.push({ ...l, reveal: true }); continue; }
    if (wsOnly.has(l.sec)) {
      if (out.length && out[out.length - 1].k === "fold" && out[out.length - 1].sec === l.sec) {
        const f = out[out.length - 1]; if (l.k === "-") f.ro++; else f.rn++;
      } else out.push({ k: "fold", sec: l.sec, ro: l.k === "-" ? 1 : 0, rn: l.k === "+" ? 1 : 0 });
      continue;
    }
    if (l.k === "+") out.push({ k: " ", s: l.s });
  }
  return { ...h, lines: out };
};

// ------------------------------------------------------------ tree
const buildTree = (files) => {
  const root = { name: "", path: "", dirs: new Map(), files: [] };
  for (const f of files) {
    const seg = f.path.split("/"); let node = root;
    for (let i = 0; i < seg.length - 1; i++) {
      const p = seg.slice(0, i + 1).join("/");
      if (!node.dirs.has(seg[i])) node.dirs.set(seg[i], { name: seg[i], path: p, dirs: new Map(), files: [] });
      node = node.dirs.get(seg[i]);
    }
    node.files.push(f);
  }
  const join = (d) => { while (!d.files.length && d.dirs.size === 1) { const c = [...d.dirs.values()][0]; d = { ...c, name: d.name + "/" + c.name }; } d.dirs = new Map([...d.dirs].map(([k, v]) => [k, join(v)])); return d; };
  root.dirs = new Map([...root.dirs].map(([k, v]) => [k, join(v)]));
  return root;
};
const filesUnder = (d) => [...d.files, ...[...d.dirs.values()].flatMap(filesUnder)];
const visibleRows = (root, closed) => {
  const out = [];
  const walk = (d, depth) => {
    for (const c of [...d.dirs.values()].sort((a, b) => a.name.localeCompare(b.name))) {
      out.push({ kind: "dir", key: "d:" + c.path, path: c.path, name: c.name, depth, files: filesUnder(c), open: !closed.has(c.path) });
      if (!closed.has(c.path)) walk(c, depth + 1);
    }
    for (const f of [...d.files].sort((a, b) => fname(a.path).localeCompare(fname(b.path)))) out.push({ kind: "file", key: "f:" + f.path, path: f.path, file: f, depth });
  };
  walk(root, 0);
  return out;
};

// ------------------------------------------------------------ small parts
function Check({ state, onToggle, label, disabled }) {
  return (
    <button className={"gck" + (state === "all" ? " on" : state === "some" ? " mixed" : "") + (disabled ? " is-off" : "")} role="checkbox" aria-checked={state === "all" ? true : state === "some" ? "mixed" : false}
      aria-disabled={!!disabled} aria-label={label} title={disabled || label} tabIndex={-1} onPointerDown={e => e.stopPropagation()}
      onClick={e => { e.stopPropagation(); if (!disabled) onToggle(); }}>
      {state === "all" && <Ic n="check" s={10}/>}{state === "some" && <Ic n="dash" s={10}/>}
    </button>
  );
}
const Stat = ({ a, r }) => <span className="isd-stat">{a > 0 && <span className="stat-add">+{a}</span>}{r > 0 && <span className="stat-rem">−{r}</span>}</span>;

// an id that copies itself: jj's prefix bold
function CopyId({ id, prefix, sub, onCopy }) {
  const [done, setDone] = useState(false);
  const copy = () => { onCopy(id); setDone(true); setTimeout(() => setDone(false), 1300); };
  const s = short(id, prefix);
  return (
    <button className={"isd-id" + (done ? " is-done" : "")} onClick={copy} title={done ? "Copied" : "Click to copy " + id}>
      <b>{s.slice(0, prefix)}</b>{s.slice(prefix)}{sub && <sub>{sub}</sub>}
    </button>
  );
}

// a menu at a point or under an anchor — rows: {label, hint, disabled, why, onClick} | "-" | {note}
function Menu({ at, rows, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState({ left: at.x, top: at.y, vis: false });
  useLayoutEffect(() => {
    const r = ref.current.getBoundingClientRect();
    setPos({ left: Math.max(8, Math.min(at.x, innerWidth - r.width - 8)), top: at.y + r.height > innerHeight - 8 ? Math.max(8, at.y - r.height) : at.y, vis: true });
  }, [at.x, at.y]);
  useEffect(() => {
    const down = (e) => { if (ref.current && !ref.current.contains(e.target)) onClose(); };
    const key = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    addEventListener("pointerdown", down, true); addEventListener("keydown", key, true);
    return () => { removeEventListener("pointerdown", down, true); removeEventListener("keydown", key, true); };
  }, [onClose]);
  // a portal: the inspector's backdrop-filter would make it the containing block of a fixed menu
  return ReactDOM.createPortal(
    <div ref={ref} className="isd-menu" role="menu" style={{ left: pos.left, top: pos.top, visibility: pos.vis ? "visible" : "hidden" }}>
      {rows.map((r, i) => r === "-" ? <div key={i} className="isd-menu-sep"/>
        : r.note ? <div key={i} className="isd-menu-note">{r.note}</div>
        : r.head ? <div key={i} className="isd-menu-head">{r.head}</div>
        : <button key={i} role="menuitem" className="isd-menu-row" disabled={r.disabled} title={r.disabled ? r.why : r.hint}
            onClick={() => { onClose(); r.onClick && r.onClick(); }}>
            {r.checked !== undefined && <span className="isd-menu-ck">{r.checked && <Ic n="check" s={11}/>}</span>}
            <span className="isd-menu-l">{r.label}</span>{r.hint && <span className="isd-menu-h">{r.hint}</span>}
          </button>)}
    </div>, document.body);
}

// ------------------------------------------------------------ diff
const numbered = (h) => {
  let o = h.oldStart, n = h.newStart;
  return h.lines.map((l) => {
    if (l.k === "fold") { const row = { ...l, at: n }; o += l.ro; n += l.rn; return row; }
    const row = { ...l, o: l.k === "+" ? null : o, n: l.k === "-" ? null : n, at: n };
    if (l.k !== "+") o++; if (l.k !== "-") n++;
    return row;
  });
};
const WS = {
  show: { label: "Show all whitespace", hint: "jj diff" },
  amount: { label: "Ignore changes in amount", hint: "jj diff -b", short: "−b" },
  all: { label: "Ignore all whitespace", hint: "jj diff -w", short: "−w" },
};
function DiffPane({ change, file, mode, setMode, viewed, setViewed, picks, togglePicks, pinned, ws, setWs, context, setContext, onMenu, onOpenMenu, onCopy }) {
  const [open, setOpen] = useState(() => new Set());
  useEffect(() => setOpen(new Set()), [file, ws]);
  const toggleOpen = (sec) => setOpen(o => { const n = new Set(o); n.has(sec) ? n.delete(sec) : n.add(sec); return n; });
  const hunks = file ? hunksOf(file).map(h => shown(h, ws, picks, open)).filter(h => h.lines.some(l => l.k !== " ")) : [];
  const [copied, setCopied] = useState(false);
  if (!file) return <div className="isd-diff isd-empty">No file</div>;
  const abs = REPO + file.path;
  const copyPath = () => { onCopy(abs); setCopied(true); setTimeout(() => setCopied(false), 1300); };
  const noPick = null;
  const nLines = (n) => n + (n === 1 ? " line" : " lines");
  const tag = (l) => l.reveal && l.k === "+" && (
    open.has(l.sec) && !picks.has(l.sec)
      ? <button className="isd-wstag" onClick={() => toggleOpen(l.sec)} title="Hide the whitespace-only lines again">whitespace only · Hide</button>
      : <span className="isd-wstag" title="Shown because its part is picked: a pick takes every line of its part">whitespace only</span>);
  const fold = (h, l, key, side) => (
    <div key={key} className={"isd-foldrow" + (side ? " is-side" : "")}>
      <span className="isd-nums">{change.mutable && <span className="isd-gut"><Check state={picks.has(l.sec) ? "all" : "none"} onToggle={() => togglePicks([l.sec])} label="Pick these whitespace-only lines"/></span>}<span/><span/></span>
      <button className="isd-foldtxt" onClick={() => toggleOpen(l.sec)} title="Show these lines">⋯ {nLines(Math.max(l.ro, l.rn))} changed whitespace only · Show</button>
    </div>
  );
  const st = (secs) => { const k = secs.filter(s => picks.has(s)).length; return !k ? "none" : k === secs.length ? "all" : "some"; };
  // diff options: whitespace (an app setting) and context lines (jj's diff.color-words.context, user config, as in Settings)
  const optionsMenu = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    onOpenMenu({ x: r.right - 260, y: r.bottom + 4 }, [
      { head: "Whitespace" },
      ...Object.entries(WS).map(([k, v]) => ({ label: v.label, hint: v.hint, checked: ws === k, onClick: () => setWs(k) })),
      "-", { head: "Context lines" },
      ...[0, 1, 2, 3, 5, 10, 20].map(n => ({ label: String(n), hint: n === 3 ? "jj's default" : undefined, checked: context === n, onClick: () => setContext(n) })),
      "-", { note: "Every diff follows these. Context lines is jj's diff.color-words.context in your user config, as in Settings › General › Diffs. A picked part shows its hidden whitespace lines, so a commit holds nothing you didn't see." },
    ]);
  };
  // the section checkbox sits on a section's first changed line, only when the hunk holds more than one
  const gutter = (h, l, first) => change.mutable && h.sections.length > 1
    ? <span className="isd-gut">{first && <Check state={picks.has(l.sec) ? "all" : "none"} onToggle={() => togglePicks([l.sec])} label={picks.has(l.sec) ? "Unpick these lines" : "Pick these lines"} disabled={noPick}/>}</span>
    : change.mutable ? <span className="isd-gut"/> : null;
  return (
    <div className={"isd-diff" + (pinned ? " is-pinned" : "")}>
      <div className="isd-dbar">
        <button className={"isd-dpath" + (copied ? " is-done" : "")} onClick={copyPath} title={copied ? "Copied" : "Click to copy " + abs}>
          <span className="isd-dname">{fname(file.path)}</span><span className="isd-ddir">{dname(file.path)}</span>
          {copied && <span className="isd-copied">Copied</span>}
        </button>
        <div className="isd-seg" role="radiogroup" aria-label="Diff layout">
          <button className={mode !== "side" ? "on" : ""} onClick={() => setMode("unified")} title="Unified"><Ic n="unified" s={13}/></button>
          <button className={mode === "side" ? "on" : ""} onClick={() => setMode("side")} title="Side by side"><Ic n="side" s={13}/></button>
        </div>
        <button className={"isd-viewed" + (viewed ? " on" : "")} onClick={() => setViewed(!viewed)} title={(viewed ? "Mark as not viewed" : "Mark as viewed") + " (V)"}>
          <span className="isd-vbox">{viewed && <Ic n="check" s={10}/>}</span>Viewed
        </button>
        <button className={"isd-optbtn" + (ws !== "show" || context !== 3 ? " on" : "")} onClick={optionsMenu} aria-haspopup="menu"
          title={`Diff options — ${WS[ws].label}, ${context} context lines`}>
          <Ic n="tune" s={14}/><Ic n="chevronDown" s={11}/>
        </button>
      </div>
      <div className="isd-dbody">
        <div className={"isd-dcontent" + (mode !== "side" ? " is-wide" : "")}>
        {viewed ? <button className="isd-folded" onClick={() => setViewed(false)}><Ic n="check" s={11}/>Viewed — diff folded away. Click to show it again.</button>
        : !hunks.length ? <div className="isd-binary">Binary file — no text diff.</div>
        : hunks.map(h => {
          const rows = numbered(h), hs = st(h.sections), seen = new Set();
          const first = (l) => l.sec && !seen.has(l.sec) && seen.add(l.sec);
          const oc = h.lines.filter(l => l.k !== "+").length, nc = h.lines.filter(l => l.k !== "-").length;
          return (
            <div key={h.id} className={"isd-hunk" + (hs === "all" ? " is-sel" : hs === "some" ? " is-some" : "")}>
              <div className="isd-hhd">
                {change.mutable && <Check state={hs} onToggle={() => togglePicks(h.sections)} label={hs === "all" ? "Unpick hunk" : "Pick hunk"} disabled={noPick}/>}
                <code>@@ −{h.oldStart},{oc} +{h.newStart},{nc} @@</code>{h.ctx && <span className="isd-hctx">{h.ctx}</span>}
                {h.sections.length > 1 && <span className="isd-nsec" title="Parts you can pick on their own">{h.sections.length} parts</span>}
                <Stat a={rows.filter(l => l.k === "+").length} r={rows.filter(l => l.k === "-").length}/>
              </div>
              {mode !== "side" ? rows.map((l, i) => l.k === "fold" ? fold(h, l, i) : (
                <div key={i} className={"isd-line k" + (l.k === "+" ? "a" : l.k === "-" ? "r" : "c") + (l.sec && picks.has(l.sec) ? " is-pick" : "") + (l.reveal ? " is-ws" : "")} onContextMenu={e => onMenu(e, { kind: "line", file, line: l.at })}>
                  <span className="isd-nums">{gutter(h, l, first(l))}<span>{l.o ?? ""}</span><span>{l.n ?? ""}</span></span>
                  <span className="isd-sig">{l.k === "+" ? "+" : l.k === "-" ? "−" : ""}</span><span className="isd-txt">{l.s}</span>{tag(l)}
                </div>
              )) : sidePairs(rows).map(([a, b], i) => {
                if (a === "fold") return fold(h, b, i, true);
                const sec = (a && a.sec) || (b && b.sec), lead = sec ? first(a && a.sec ? a : b) : false;
                return (
                  <div key={i} className={"isd-srow" + (sec && picks.has(sec) ? " is-pick" : "")}>
                    {gutter(h, { sec }, lead)}
                    {[a, b].map((x, j) => (
                      <div key={j} className={"isd-side" + (!x ? " is-blank" : x.k === "+" ? " ka" : x.k === "-" ? " kr" : " kc") + (x && x.reveal ? " is-ws" : "")}
                        onContextMenu={x ? e => onMenu(e, { kind: "line", file, line: x.at }) : undefined}>
                        <span className="isd-num">{x ? (j ? x.n : x.o) ?? "" : ""}</span><span className="isd-txt">{x ? x.s : ""}</span>
                      </div>
                    ))}
                  </div>
                );
              })}
            </div>
          );
        })}
        </div>
      </div>
    </div>
  );
}
const sidePairs = (rows) => {
  const out = []; let i = 0;
  while (i < rows.length) {
    if (rows[i].k === "fold") { out.push(["fold", rows[i]]); i++; continue; }
    if (rows[i].k === " ") { out.push([rows[i], rows[i]]); i++; continue; }
    const rem = [], add = [];
    while (i < rows.length && rows[i].k === "-") rem.push(rows[i++]);
    while (i < rows.length && rows[i].k === "+") add.push(rows[i++]);
    for (let k = 0; k < Math.max(rem.length, add.length); k++) out.push([rem[k] || null, add[k] || null]);
  }
  return out;
};

// ------------------------------------------------------------ files
function FilesPane({ change, files, view, setView, focus, setFocus, picks, togglePicks, viewed, setViewed, noPick, onMenu, onCopy }) {
  const tree = useMemo(() => buildTree(files), [files]);
  const [closed, setClosed] = useState(() => new Set());
  const rows = useMemo(() => (view === "tree" ? visibleRows(tree, closed)
    : files.map(f => ({ kind: "file", key: "f:" + f.path, path: f.path, file: f, depth: 0 }))), [view, tree, closed, files]);
  const [cur, setCur] = useState(() => "f:" + (focus || ""));
  const listRef = useRef(null);
  useEffect(() => { if (!rows.some(r => r.key === cur) && focus) setCur("f:" + focus); }, [rows, cur, focus]);
  useEffect(() => { const el = listRef.current && listRef.current.querySelector(".is-cur"); if (el) el.scrollIntoView({ block: "nearest" }); }, [cur]);

  const hunkIds = sectionsOf;
  const pickState = (fs) => { const ids = hunkIds(fs); const k = ids.filter(id => picks.has(id)).length; return !ids.length || !k ? "none" : k === ids.length ? "all" : "some"; };
  const tot = files.reduce((s, f) => ({ a: s.a + f.a, r: s.r + f.r }), { a: 0, r: 0 });
  const vN = files.filter(f => viewed[f.path]).length;
  const select = (r) => { setCur(r.key); if (r.kind === "file") setFocus(r.path); };
  const toggleDir = (path, open) => setClosed(c => { const n = new Set(c); (open ?? n.has(path)) ? n.delete(path) : n.add(path); return n; });

  const key = (e) => {
    const i = rows.findIndex(r => r.key === cur), r = rows[i];
    const go = (j) => { e.preventDefault(); if (rows[j]) select(rows[j]); };
    if (e.key === "ArrowDown") return go(Math.min(rows.length - 1, i + 1));
    if (e.key === "ArrowUp") return go(Math.max(0, i - 1));
    if (!r) return;
    if (e.key === "ArrowLeft" && view === "tree") {
      e.preventDefault();
      if (r.kind === "dir" && r.open) return toggleDir(r.path, false);
      for (let j = i - 1; j >= 0; j--) if (rows[j].kind === "dir" && rows[j].depth < r.depth) return select(rows[j]);
      return;
    }
    if (e.key === "ArrowRight" && view === "tree" && r.kind === "dir") { e.preventDefault(); return r.open ? go(i + 1) : toggleDir(r.path, true); }
    if (e.key === " " && change.mutable && !noPick) { e.preventDefault(); return togglePicks(hunkIds(r.kind === "dir" ? r.files : [r.file])); }
    if ((e.key === "v" || e.key === "V") && !e.metaKey) { e.preventDefault(); const fs = r.kind === "dir" ? r.files : [r.file]; const on = !fs.every(f => viewed[f.path]); return setViewed(fs.map(f => f.path), on); }
    if (e.key === "c" && e.metaKey) { e.preventDefault(); return onCopy(REPO + r.path); }
    if (e.key === "Enter" && r.kind === "dir") { e.preventDefault(); return toggleDir(r.path); }
  };

  return (
    <div className="isd-files">
      <div className="isd-fhd">
        {change.mutable && <Check state={pickState(files)} onToggle={() => togglePicks(hunkIds(files))} label="Pick all" disabled={noPick}/>}
        <span className="isd-ftitle">Changes</span>
        <span className="isd-fmeta">{files.length} {files.length === 1 ? "file" : "files"} <Stat a={tot.a} r={tot.r}/></span>
        {vN > 0 && <span className="isd-fviewed">{vN === files.length ? <><Ic n="check" s={10}/> all viewed</> : `${vN}/${files.length} viewed`}
          <button onClick={() => setViewed(files.map(f => f.path), vN !== files.length)}>{vN === files.length ? "Reset" : "Mark all"}</button></span>}
        <div className="isd-seg isd-fview" role="radiogroup" aria-label="File list">
          <button className={view !== "tree" ? "on" : ""} onClick={() => setView("flat")} title="Flat list"><Ic n="flat" s={13}/></button>
          <button className={view === "tree" ? "on" : ""} onClick={() => setView("tree")} title="Tree"><Ic n="tree" s={13}/></button>
        </div>
      </div>
      <div className="isd-flist" role="tree" tabIndex={0} ref={listRef} onKeyDown={key} aria-label="Changed files">
        {rows.map(r => {
          const isCur = r.key === cur, pad = { paddingLeft: 8 + r.depth * 14 };
          if (r.kind === "dir") {
            const st = r.files.reduce((s, f) => ({ a: s.a + f.a, r: s.r + f.r }), { a: 0, r: 0 });
            return (
              <div key={r.key} role="treeitem" aria-expanded={r.open} className={"isd-row is-dir" + (isCur ? " is-cur" : "")} style={pad}
                onClick={() => { select(r); toggleDir(r.path); }} onContextMenu={e => { select(r); onMenu(e, { kind: "dir", path: r.path }); }}
                title={r.path}>
                <span className="isd-chev"><Ic n={r.open ? "chevronDown" : "chevronRight"} s={12}/></span>
                {change.mutable && <Check state={pickState(r.files)} onToggle={() => togglePicks(hunkIds(r.files))} label={"Pick " + r.name} disabled={noPick}/>}
                <span className="isd-fold"><Ic n="folder" s={13}/></span>
                <span className="isd-dirname">{r.name}</span>
                <span className="isd-count">{r.files.length}</span>
                <Stat a={st.a} r={st.r}/>
              </div>
            );
          }
          const f = r.file, dir = dname(f.path), cut = dir.lastIndexOf("/");
          return (
            <div key={r.key} role="treeitem" className={"isd-row" + (isCur ? " is-cur" : "") + (focus === f.path ? " is-focus" : "") + (viewed[f.path] ? " is-viewed" : "")}
              style={view === "tree" ? { paddingLeft: 8 + r.depth * 14 + 18 } : undefined}
              onClick={() => select(r)} onContextMenu={e => { select(r); onMenu(e, { kind: "file", file: f }); }} title={f.path}>
              {change.mutable && <Check state={pickState([f])} onToggle={() => togglePicks(hunkIds([f]))} label={"Pick " + fname(f.path)} disabled={noPick}/>}
              <span className={"isd-st st-" + f.status}>{f.status}</span>
              <span className="isd-name">{fname(f.path)}</span>
              {view !== "tree" && dir && <span className="isd-dir"><span className="h">{cut < 0 ? "" : dir.slice(0, cut + 1)}</span><span className="t">{cut < 0 ? dir : dir.slice(cut + 1)}</span></span>}
              {viewed[f.path] && <span className="isd-vw" title="Viewed"><Ic n="check" s={10}/></span>}
              <Stat a={f.a} r={f.r}/>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ------------------------------------------------------------ composer — the command cut in its message, never in its paths
function Composer({ change, files, picks, clear }) {
  const [s, setS] = useState(""), [b, setB] = useState("");
  const all = sectionsOf(files);
  const everything = all.length > 0 && all.every(id => picks.has(id));
  const paths = files.filter(f => hunksOf(f).some(h => picks.has(h.id))).map(f => f.path);
  const verb = change.wc ? "jj commit" : `jj split -r ${short(change.id, change.prefix)}`;
  const msg = (s + (b ? "\n\n" + b : "")).trim();
  const tail = change.wc && everything ? "" : " " + paths.join(" ");
  const full = `${verb} -m '${msg}'${tail}`;
  const disabled = !change.wc && everything;
  return (
    <div className="gcomp">
      <div className="gdesc-fields">
        <input className="gdesc-subj" value={s} onChange={e => setS(e.target.value)} placeholder={change.wc ? "Summary of what you did" : "Summary of the selected changes"}/>
        <textarea className="gdesc-body" value={b} onChange={e => setB(e.target.value)} placeholder="Details (optional)" rows={2}/>
      </div>
      <div className="gcomp-ft">
        <code className="isd-cmd" title={full}><span className="v">{verb} -m '</span><span className="m">{msg}</span><span className="v">'</span><span className="p">{tail}</span></code>
        {!change.wc && <button className="gins-btn" onClick={clear}>Cancel</button>}
        <button className="gins-btn primary" disabled={disabled} onClick={clear}
          title={disabled ? "Every change is picked. To describe this change, click its title." : full}>{change.wc ? "Commit" : "Split"}</button>
      </div>
      {disabled && <div className="gcomp-hint">Every change is picked — Split needs something left behind. To describe this change, click its title.</div>}
    </div>
  );
}

// ------------------------------------------------------------ inspector
function Inspector({ change, width, wide, ratio, setRatio, view, setView, mode, setMode, pinned, ws, setWs, context, setContext, editor, onSelect, onCopy, toast, onClose }) {
  const files = change.files;
  const [focus, setFocus] = useState(files[0] && files[0].path);
  useEffect(() => { setFocus(files[0] && files[0].path); }, [change]);
  const file = files.find(f => f.path === focus) || files[0];
  const [picks, setPicks] = useState(() => new Set());
  useEffect(() => { setPicks(new Set(change.wc ? sectionsOf(files) : [])); }, [change]);
  const togglePicks = (ids) => setPicks(p => { const n = new Set(p); const on = ids.every(id => n.has(id)); ids.forEach(id => on ? n.delete(id) : n.add(id)); return n; });
  const [viewedAll, setViewedAll] = useStored("viewed", {});
  const viewed = viewedAll[change.id] || {};
  const setViewed = (paths, on) => setViewedAll(v => { const m = { ...(v[change.id] || {}) }; paths.forEach(p => on ? (m[p] = true) : delete m[p]); return { ...v, [change.id]: m }; });
  const [more, setMore] = useState(false), [clamped, setClamped] = useState(false);
  const descRef = useRef(null);
  useLayoutEffect(() => { setMore(false); }, [change]);
  useLayoutEffect(() => { const el = descRef.current; setClamped(!!el && el.scrollHeight > el.clientHeight + 1); }, [change, width, more]);
  const [menu, setMenu] = useState(null);
  const splitRef = useRef(null);

  const onDisk = !change.wc ? "Opens the file on disk — @'s version; a later change may have moved its lines." : null;
  const openRow = (path, line) => editor === "none"
    ? { label: "Choose editor…", hint: "Settings › General › Editor", onClick: () => toast("Opens Settings › General › Editor") }
    : { label: line ? "Open in IntelliJ IDEA at line " + line : "Open in IntelliJ IDEA", hint: line ? `idea --line ${line}` : "idea", onClick: () => toast(`Runs: idea ${line ? "--line " + line + " " : ""}${REPO + path}`) };
  const reveal = (path) => ({ label: "Reveal in Finder", hint: "open -R", onClick: () => toast("Runs: open -R " + REPO + path) });
  const copy = (label, text, hint) => ({ label, hint, onClick: () => onCopy(text) });
  const showMenu = (e, what) => {
    e.preventDefault();
    const at = { x: e.clientX, y: e.clientY };
    const rows = what.kind === "file" ? [openRow(what.file.path), reveal(what.file.path), "-", copy("Copy path", REPO + what.file.path, "⌘C"), copy("Copy relative path", what.file.path), ...(onDisk ? ["-", { note: onDisk }] : [])]
      : what.kind === "dir" ? [reveal(what.path), "-", copy("Copy path", REPO + what.path, "⌘C"), copy("Copy relative path", what.path)]
      : what.kind === "line" ? [openRow(what.file.path, what.line), "-", copy("Copy path:line", `${REPO + what.file.path}:${what.line}`), copy("Copy path", REPO + what.file.path), ...(onDisk ? ["-", { note: onDisk }] : [])]
      : [copy("Copy name", what.name)];
    setMenu({ at, rows });
  };
  const squashMenu = (e) => {
    const r = e.currentTarget.getBoundingClientRect(), id = short(change.id, change.prefix);
    setMenu({ at: { x: r.left, y: r.bottom + 4 }, rows: [
      { label: "Squash into parent", hint: `jj squash -r ${id}`, onClick: () => toast(`Runs: jj squash -r ${id}`) },
      { label: "Absorb into ancestors", hint: `jj absorb --from ${id}`, disabled: !!change.absorbReason, why: change.absorbReason, onClick: () => toast(`Runs: jj absorb --from ${id}`) },
    ] });
  };

  // the divider: the files' share of the split, per layout
  const drag = (e) => {
    e.preventDefault();
    const box = splitRef.current.getBoundingClientRect(), total = wide ? box.width : box.height;
    const minF = wide ? 220 : 110, minD = wide ? 320 : 140;
    const move = (ev) => { const v = (wide ? ev.clientX - box.left : ev.clientY - box.top); setRatio(Math.min(total - minD, Math.max(minF, v)) / total); };
    const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); document.body.classList.remove("isd-dragging"); };
    document.body.classList.add("isd-dragging"); addEventListener("pointermove", move); addEventListener("pointerup", up);
  };
  const composing = change.mutable && (change.wc ? files.length > 0 : picks.size > 0);
  const id8 = short(change.id, change.prefix);

  return (
    <section className={"isd-ins gins" + (wide ? " is-wide" : " is-narrow")} style={{ width }}>
      <header className="gins-hd">
        <span className="isd-ids"><CopyId id={change.id} prefix={change.prefix} sub="jj" onCopy={onCopy}/><CopyId id={change.commit + "0f3a9be2c71d"} prefix={change.cprefix} sub="git" onCopy={onCopy}/></span>
        <span className="gins-flags">
          {change.wc && <span className="gins-flag wc">@ Working copy</span>}
          {change.immutable && <span className="gins-flag"><span className="isd-hatch"/>Immutable</span>}
        </span>
        <button className="bcd-close" onClick={onClose} title="Close (Esc)" aria-label="Close"><Ic n="close" s={12}/></button>
      </header>
      <div className="isd-top">
        <div className={"gins-title" + (change.mutable ? " is-editable" : "")} title={change.mutable ? "Edit description — jj describe" : undefined}>
          <h2 className={"gins-subj" + (!change.subject ? " is-dim" : "")}>{change.subject || "Describe this change…"}{change.mutable && <Ic n="pen" s={12} c="gins-pen"/>}</h2>
          {change.description && <p ref={descRef} className={"gins-desc isd-desc" + (more ? " is-open" : "")}>{change.description}</p>}
          {change.description && (clamped || more) && <button className="isd-more" onClick={e => { e.stopPropagation(); setMore(!more); }}>{more ? "Show less" : "Show more"}</button>}
        </div>
        <div className="gins-meta">
          <span>{change.author}</span><span>{change.date}</span>
          <span className="isd-parents">{change.parents.length > 1 ? "parents" : "parent"}&nbsp;
            {change.parents.map((p, i) => {
              const c = CHANGES[p], inGraph = !!c;
              return (
                <React.Fragment key={p}>{i > 0 && " + "}
                  {inGraph ? <CopyId id={c.id} prefix={c.prefix} onCopy={onCopy}/> : <span className="isd-id plain">{p}</span>}
                  <button className="isd-jump" disabled={!inGraph} onClick={() => onSelect(p)}
                    title={inGraph ? "Select parent " + short(c.id, c.prefix) : `Parent ${p} is not in the shown graph`} aria-label="Select parent"><Ic n="parent" s={12}/></button>
                </React.Fragment>
              );
            })}
          </span>
        </div>
        {change.bookmarks.length > 0 && (
          <div className="gins-bms isd-bms">
            {change.bookmarks.map(b => (
              <span key={b} className="gdetail-bm" title={b + " · in sync with origin · right-click to copy"} onContextMenu={e => showMenu(e, { kind: "chip", name: b })}>
                <Ic n="bookmark" s={11}/><span className="gins-bm-name">{b}</span><span className="gbm-state s-synced">✓</span>
              </span>
            ))}
          </div>
        )}
        <div className="gins-act">
          {!change.mutable ? <button className="gins-btn primary" title={`jj new ${id8}`}><Ic n="plus" s={13}/><span>New change on top</span></button> : <>
            {change.wc ? <button className="gins-btn primary" title={`jj new ${id8}`}>New change</button>
              : <button className="gins-btn primary" title={`jj edit ${id8}`}><span className="gat sm">@</span><span>Edit</span></button>}
            <button className="gins-btn isd-menubtn" onClick={squashMenu} aria-haspopup="menu" title="Squash or absorb into earlier changes">Squash<Ic n="chevronDown" s={12}/></button>
            <button className="gins-btn danger" title={`jj abandon ${id8}`}>Abandon</button>
          </>}
        </div>
      </div>
      <div className="isd-split" ref={splitRef} style={{ "--files": (ratio * 100).toFixed(2) + "%" }}>
        <FilesPane change={change} files={files} view={view} setView={setView} focus={focus} setFocus={setFocus} picks={picks} togglePicks={togglePicks}
          viewed={viewed} setViewed={setViewed} noPick={null} onMenu={showMenu} onCopy={onCopy}/>
        <div className="isd-divider" onPointerDown={drag} onDoubleClick={() => setRatio(wide ? 0.34 : 0.38)} role="separator" aria-orientation={wide ? "vertical" : "horizontal"} title="Drag to resize · double-click to reset"/>
        <DiffPane change={change} file={file} mode={mode} setMode={setMode} viewed={!!(file && viewed[file.path])} setViewed={(on) => file && setViewed([file.path], on)}
          picks={picks} togglePicks={togglePicks} pinned={pinned} ws={ws} setWs={setWs} context={context} setContext={setContext} onMenu={showMenu} onOpenMenu={(at, rows) => setMenu({ at, rows })} onCopy={onCopy}/>
      </div>
      {composing && <Composer change={change} files={files} picks={picks} clear={() => setPicks(new Set())}/>}
      {menu && <Menu at={menu.at} rows={menu.rows} onClose={() => setMenu(null)}/>}
    </section>
  );
}

// ------------------------------------------------------------ app: a window with a graph stand-in and the inspector
const LEFT = 76, GAP = 24, GRAPH = 320, MIN = 380, WIDE_IN = 780, WIDE_OUT = 740;
function App() {
  const [theme, setTheme] = useStored("theme", "dark");
  const [width, setWidth] = useStored("width", 460);
  const [ratios, setRatios] = useStored("ratios", { narrow: 0.38, wide: 0.34 });
  const [view, setView] = useStored("view", "flat");
  const [mode, setMode] = useStored("mode", "unified");
  const [pinned, setPinned] = useStored("pinned", true);
  const [editor, setEditor] = useStored("editor", "idea");
  const [sel, setSel] = useStored("sel", "rqxsqwnr");
  const [ws, setWs] = useStored("ws", "show");
  const [context, setContext] = useStored("context", 3);
  const [winW, setWinW] = useState(innerWidth);
  const [msg, setMsg] = useState(null);
  const wideRef = useRef(width >= WIDE_IN);
  useEffect(() => { document.documentElement.dataset.theme = theme; }, [theme]);
  useEffect(() => { const r = () => setWinW(innerWidth); addEventListener("resize", r); return () => removeEventListener("resize", r); }, []);
  const max = Math.max(MIN, winW - LEFT - GAP - GRAPH);
  const w = Math.min(Math.max(width, MIN), max);
  // hysteresis: the layout flips at 780 going wider and at 740 going narrower
  if (w >= WIDE_IN) wideRef.current = true; else if (w < WIDE_OUT) wideRef.current = false;
  const wide = wideRef.current;
  const toast = useCallback((t) => { setMsg(t); clearTimeout(toast.t); toast.t = setTimeout(() => setMsg(null), 2600); }, []);
  const onCopy = useCallback((t) => { try { navigator.clipboard.writeText(t); } catch { /* no clipboard */ } toast("Copied: " + t); }, [toast]);
  const edge = (e) => {
    e.preventDefault();
    const move = (ev) => setWidth(Math.round(Math.min(max, Math.max(MIN, innerWidth - 12 - ev.clientX))));
    const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); document.body.classList.remove("isd-dragging-x"); };
    document.body.classList.add("isd-dragging-x"); addEventListener("pointermove", move); addEventListener("pointerup", up);
  };
  const seg = (val, set, opts) => <div className="isd-seg">{opts.map(([v, l]) => <button key={String(v)} className={val === v ? "on" : ""} onClick={() => set(v)}>{l}</button>)}</div>;
  const change = sel && CHANGES[sel];
  return (
    <div className="isd-win is-float">
      <div className="isd-study">
        <b>Inspector study</b>
        {seg(theme, setTheme, [["dark", "Night"], ["light", "Paper"]])}
        {seg(null, (v) => setWidth(v), [[460, "460"], [760, "760"], [1100, "1100"], [max, "max"]])}
        <span className="isd-wv">{w}px · {wide ? "wide" : "narrow"}</span>
        <span className="isd-lab">Line numbers</span>{seg(pinned, setPinned, [[true, "Pinned"], [false, "Scroll"]])}
        <span className="isd-lab">Editor</span>{seg(editor, setEditor, [["idea", "IntelliJ"], ["none", "None"]])}
        <span className="isd-hint">Right-click rows, lines, chips · in the file list ↑↓ ←→ Space V ⌘C</span>
      </div>
      <div className="isd-rail"/>
      <div className="isd-graph">
        {ORDER.map((k, i) => {
          const c = CHANGES[k];
          return (
            <button key={k} className={"isd-card" + (sel === k ? " is-sel" : "") + (c.wc ? " is-wc" : "") + (c.immutable ? " is-imm" : "")} onClick={() => setSel(k)} style={{ top: 40 + i * 120 }}>
              <span className="isd-card-s">{c.subject || "(no description set)"}</span>
              <span className="isd-card-m">{c.wc && <span className="gat sm">@</span>}<b>{c.id.slice(0, c.prefix)}</b>{c.id.slice(c.prefix, 8)} · {c.files.length} files</span>
            </button>
          );
        })}
      </div>
      {change && <>
        <div className="isd-edge" style={{ right: 12 + w - 3 }} onPointerDown={edge} title="Drag to resize the inspector"/>
        <div className="isd-slot" style={{ width: w }}>
          <Inspector key={sel} change={change} width={w} wide={wide} ratio={wide ? ratios.wide : ratios.narrow}
            setRatio={(r) => setRatios(x => ({ ...x, [wide ? "wide" : "narrow"]: r }))}
            view={view} setView={setView} mode={mode} setMode={setMode} pinned={pinned} ws={ws} setWs={setWs} context={context} setContext={setContext} editor={editor}
            onSelect={setSel} onCopy={onCopy} toast={toast} onClose={() => setSel(null)}/>
        </div>
      </>}
      {msg && <div className="isd-toast" role="status">{msg}</div>}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
})();
