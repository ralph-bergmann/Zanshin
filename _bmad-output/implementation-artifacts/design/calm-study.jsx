/* global React, ReactDOM */
// CALM INSPECTOR STUDY (2026-11-15): less on screen. Folders show open/closed in their icon (no chevron),
// checkboxes appear only while the pointer (or keyboard focus) is in their pane unless something is picked,
// no +/- counts, no status letter for a plain modification, no hunk header: the gaps between hunks become
// rows that open more context, their controls shown only while the pointer is in the code.
(() => {
const { useState } = React;

// ------------------------------------------------------------ icons
const P = {
  check: <path d="M3 8.5l3 3 7-7" stroke="currentColor" strokeWidth="1.8" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  dash: <path d="M4 8h8" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>,
  folder: <path d="M2.5 4.5h4l1.5 1.5h5.5v6.5h-11V4.5z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"/>,
  folderOpen: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"><path d="M2.5 12.5v-8h4l1.5 1.5h4.5v1.5"/><path d="M2.5 12.5l1.8-5h10l-1.8 5z"/></g>,
  up: <path d="M4.5 9.5L8 6l3.5 3.5" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  down: <path d="M4.5 6.5L8 10l3.5-3.5" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  both: <g stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M5 5.5L8 2.5l3 3M5 10.5l3 3 3-3"/></g>,
  flat: <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"><path d="M3 4.5h10M3 8h10M3 11.5h10"/></g>,
  tree: <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" fill="none"><path d="M3 3.5h5M5.5 7.5h7.5M5.5 11.5h7.5M3.5 3.5v8h2"/><path d="M3.5 7.5h2"/></g>,
  unified: <g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="2" y="3" width="12" height="10" rx="1.2"/><path d="M2 8h12"/></g>,
  side: <g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="2" y="3" width="12" height="10" rx="1.2"/><path d="M8 3v10"/></g>,
  branch: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinecap="round"><circle cx="5" cy="4" r="1.5"/><circle cx="5" cy="12" r="1.5"/><circle cx="11" cy="6" r="1.5"/><path d="M5 5.5v5M11 7.5c0 2-6 1.5-6 3"/></g>,
};
const Ic = ({ n, s = 14 }) => <svg width={s} height={s} viewBox="0 0 16 16" aria-hidden="true">{P[n]}</svg>;

function Check({ state, onToggle, label }) {
  return (
    <button className={"gck" + (state === "all" ? " on" : state === "some" ? " mixed" : "")} role="checkbox"
      aria-checked={state === "all" ? true : state === "some" ? "mixed" : false} aria-label={label} title={label}
      onClick={(e) => { e.stopPropagation(); onToggle(); }}>
      {state === "all" && <Ic n="check" s={10}/>}{state === "some" && <Ic n="dash" s={10}/>}
    </button>
  );
}

// ------------------------------------------------------------ the file shown in the diff (Ralph's WMMA-505 change)
const SRC = `+import 'package:app_logger/app_logger.dart';
 import 'package:design/design.dart';
 import 'package:flutter/material.dart';
 import 'package:flutter_riverpod/flutter_riverpod.dart';
 import 'package:localization/localization.dart';
+import 'package:logic_designer/src/domain/models/automation.dart';
 import 'package:logic_designer/src/presentation/providers/automations_provider.dart';
 import 'package:logic_designer/src/presentation/widgets/automation_card.dart';
 import 'package:logic_designer/src/presentation/widgets/function_wizard_dialog.dart';

 /// Lists the automations of a building and opens the function wizard.
 class AutomationOverviewPage extends ConsumerStatefulWidget {
   const AutomationOverviewPage({super.key});

   @override
   ConsumerState<AutomationOverviewPage> createState() => _AutomationOverviewPageState();
 }

 class _AutomationOverviewPageState extends ConsumerState<AutomationOverviewPage> {
+  Future<void> _retry() async {
+    ref.invalidate(automationsProvider);
+    try {
+      await ref.read(automationsProvider.future);
+    } on Object catch (error, stackTrace) {
+      logger.e('Failed to reload the automations', error: error, stackTrace: stackTrace);
+    }
+  }
+
   @override
   Widget build(BuildContext context) {
     final s = context.strings;
-    final automations = ref.watch(automationsProvider).value;
+    final automationsState = ref.watch(automationsProvider);

     return Scaffold(
       floatingActionButton: Semantics(
         identifier: SemanticsIdentifiers.automationOverview_add,
         child: FloatingActionButton(
           onPressed: () => showFunctionWizardDialog(context),
           tooltip: s.automationOverview_add,
           child: const Icon(Icons.add),
         ),
       ),
       body: NestedScrollView(
         headerSliverBuilder: (context, _) => [
           ViegaExpandableAppBar(title: s.automationOverview_title, leading: const BackButton()),
         ],
         body: DynamicRestrictedWidth(
-          child: automations == null
-              ? const Center(child: CircularProgressIndicator())
-              : _buildList(context, automations),
+          child: _buildBody(context, automationsState),
         ),
       ),
     );
   }

+  Widget _buildBody(BuildContext context, AsyncValue<List<Automation>> automationsState) {
+    final automations = automationsState.value;
+    if (automations == null && automationsState.hasError) {
+      return ViegaListEmpty(type: .error, buttonIdentifier: SemanticsIdentifiers.automationOverview_retry, action: _retry);
+    }
+    if (automations == null) return const Center(child: CircularProgressIndicator());
+    return _buildList(context, automations);
+  }
+
   Widget _buildList(BuildContext context, List<Automation> automations) {
     return ListView(
       // Leaves room for the floating action button.
       padding: context.marginSymmetric(horizontal: true) + const EdgeInsets.only(bottom: SpacePrimitives.spacing96),
       children: [
         for (final automation in automations)
           Padding(
             padding: const EdgeInsets.only(bottom: SpacePrimitives.spacing8),
             child: AutomationCard(
               automation: automation,
               onTap: () => _open(context, automation),
               onDelete: () => _confirmDelete(context, automation),
             ),
           ),
       ],
     );
   }

   void _open(BuildContext context, Automation automation) {
     showFunctionWizardDialog(context, automation: automation);
   }

   Future<void> _confirmDelete(BuildContext context, Automation automation) async {
     final s = context.strings;
     final confirmed = await showDialog<bool>(
       context: context,
       builder: (context) => AlertDialog(
         title: Text(s.automationOverview_deleteTitle),
         content: Text(s.automationOverview_deleteBody(automation.name)),
         actions: [
           TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.common_cancel)),
           TextButton(onPressed: () => Navigator.pop(context, true), child: Text(s.common_delete)),
         ],
       ),
     );
     if (confirmed != true || !context.mounted) return;
     await ref.read(automationRepositoryProvider).delete(automation.id);
+    ref.invalidate(automationsProvider);
   }

   @override
   void dispose() {
     _scrollController.dispose();
     super.dispose();
   }
 }`;
const ROWS = (() => {
  let o = 0, n = 0;
  return SRC.split("\n").map((t) => {
    const k = t[0] || " ", s = t.slice(1); // a blank context line may have lost its leading space
    return { k, s, o: k !== "+" ? ++o : null, n: k !== "-" ? ++n : null };
  });
})();
// A section: a run of changed lines between unchanged ones — what can be picked on its own.
const SECTIONS = [];
ROWS.forEach((r, i) => {
  if (r.k === " ") return;
  if (i > 0 && ROWS[i - 1].k !== " ") r.sec = ROWS[i - 1].sec;
  else { r.sec = "ov#" + SECTIONS.length; r.first = true; SECTIONS.push(r.sec); }
});
const CONTEXT = 3, STEP = 20;
const near = (i) => ROWS.slice(Math.max(0, i - CONTEXT), i + CONTEXT + 1).some((r) => r.k !== " ");

// ------------------------------------------------------------ the change's files
const FILES = [
  { path: "packages/design/lib/src/constants/semantics_identifiers.dart", status: "M", secs: ["si#0"] },
  { path: "packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart", status: "M", secs: SECTIONS },
  { path: "packages/logic_designer/pubspec.yaml", status: "M", secs: ["pub#0"] },
  { path: "packages/logic_designer/test/presentation/widgets/automation_overview_page_test.dart", status: "A", secs: ["test#0"] },
];
const fname = (p) => p.split("/").pop();
const dname = (p) => p.slice(0, Math.max(0, p.lastIndexOf("/")));
const buildTree = (files) => {
  const root = { name: "", path: "", dirs: new Map(), files: [] };
  for (const f of files) {
    const seg = f.path.split("/"); let node = root;
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
const rowsOf = (root, closed) => {
  const out = [];
  const walk = (d, depth) => {
    for (const c of d.dirs.values()) {
      out.push({ kind: "dir", path: c.path, name: c.name, depth, files: filesUnder(c), open: !closed.has(c.path) });
      if (!closed.has(c.path)) walk(c, depth + 1);
    }
    for (const f of d.files) out.push({ kind: "file", path: f.path, file: f, depth });
  };
  walk(root, 0);
  return out;
};
const TREE = buildTree(FILES);
const stateOf = (secs, picks) => { const k = secs.filter((s) => picks.has(s)).length; return !k ? "none" : k === secs.length ? "all" : "some"; };

// ------------------------------------------------------------ files pane
function FilesPane({ picks, toggle, focus, setFocus }) {
  const [closed, setClosed] = useState(() => new Set());
  const [view, setView] = useState("tree");
  const rows = view === "tree" ? rowsOf(TREE, closed) : FILES.map((f) => ({ kind: "file", path: f.path, file: f, depth: 0 }));
  const all = FILES.flatMap((f) => f.secs);
  return (
    <div className="cs-files" tabIndex={-1}>
      <div className="cs-fhd">
        <span className="cs-gut"><Check state={stateOf(all, picks)} onToggle={() => toggle(all)} label="Pick all"/></span>
        <span className="cs-ftitle">Changes</span><span className="cs-fmeta">{FILES.length} files</span>
        <div className="isd-seg cs-fview" role="radiogroup" aria-label="File list">
          <button className={view !== "tree" ? "on" : ""} onClick={() => setView("flat")} title="Flat list"><Ic n="flat" s={13}/></button>
          <button className={view === "tree" ? "on" : ""} onClick={() => setView("tree")} title="Tree"><Ic n="tree" s={13}/></button>
        </div>
      </div>
      <div className="cs-flist" role="tree">
        {rows.map((r) => {
          const ind = { paddingLeft: r.depth * 14 };
          if (r.kind === "dir") {
            const secs = r.files.flatMap((f) => f.secs);
            return (
              <div key={"d" + r.path} role="treeitem" aria-expanded={r.open} className="cs-row is-dir" title={r.path}
                onClick={() => setClosed((c) => { const n = new Set(c); n.has(r.path) ? n.delete(r.path) : n.add(r.path); return n; })}>
                <span className="cs-gut"><Check state={stateOf(secs, picks)} onToggle={() => toggle(secs)} label={"Pick " + r.name}/></span>
                <span className="cs-ind" style={ind}><span className="cs-ficon"><Ic n={r.open ? "folderOpen" : "folder"} s={14}/></span>{r.name}</span>
              </div>
            );
          }
          const f = r.file;
          return (
            <div key={"f" + r.path} role="treeitem" className={"cs-row" + (focus === f.path ? " is-cur" : "")} title={f.path} onClick={() => setFocus(f.path)}>
              <span className="cs-gut"><Check state={stateOf(f.secs, picks)} onToggle={() => toggle(f.secs)} label={"Pick " + fname(f.path)}/></span>
              <span className="cs-ind" style={view === "tree" ? { paddingLeft: r.depth * 14 + 20 } : undefined}>
                <span className="cs-name">{fname(f.path)}</span>
                {f.status === "A" && <span className="cs-new" title="Added in this change">new</span>}
                {view !== "tree" && <span className="cs-dir">{dname(f.path)}</span>}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ------------------------------------------------------------ diff pane
function DiffPane({ picks, toggle }) {
  const [shown, setShown] = useState(() => new Set());
  const vis = (i) => near(i) || shown.has(i);
  const reveal = (from, to) => setShown((s) => { const n = new Set(s); for (let i = from; i < to; i++) n.add(i); return n; });
  // Rows, with every hidden run turned into one gap row.
  const items = [];
  for (let i = 0; i < ROWS.length; i++) {
    if (vis(i)) { items.push({ row: ROWS[i], i }); continue; }
    let j = i; while (j < ROWS.length && !vis(j)) j++;
    items.push({ gap: true, from: i, to: j, top: i === 0, bottom: j === ROWS.length });
    i = j - 1;
  }
  const gap = (g) => {
    const n = g.to - g.from, small = n <= STEP;
    const btn = (icon, title, a, b) => <button className="cs-gbtn" title={title} onClick={() => reveal(a, b)}><Ic n={icon} s={14}/></button>;
    return (
      <div key={"g" + g.from} className="cs-gap">
        <span className="cs-gut"/>
        <span className="cs-gnums">
          {small ? btn("both", `Show ${n} lines`, g.from, g.to) : <>
            {!g.top && btn("down", `Show ${STEP} lines below`, g.from, g.from + STEP)}
            {!g.bottom && btn("up", `Show ${STEP} lines above`, g.to - STEP, g.to)}
          </>}
        </span>
        <span className="cs-gtxt">{n} unchanged {n === 1 ? "line" : "lines"}</span>
        {!small && <button className="cs-gall" onClick={() => reveal(g.from, g.to)}>Show all</button>}
      </div>
    );
  };
  return (
    <div className="isd-diff cs-code" tabIndex={-1}>
      <div className="isd-dbar">
        <span className="isd-dpath"><span className="isd-dname">automation_overview_page.dart</span><span className="isd-ddir">packages/logic_designer/lib/src/presentation/widgets/</span></span>
        <div className="isd-seg" role="radiogroup" aria-label="Diff layout">
          <button className="on" title="Unified"><Ic n="unified" s={13}/></button>
          <button title="Side by side"><Ic n="side" s={13}/></button>
        </div>
        <button className="isd-viewed"><span className="isd-vbox"/>Viewed</button>
      </div>
      <div className="isd-dbody">
        <div className="isd-dcontent is-wide">
          {items.map((it) => {
            if (it.gap) return gap(it);
            const l = it.row, picked = l.sec && picks.has(l.sec);
            return (
              <div key={it.i} className={"isd-line cs-line k" + (l.k === "+" ? "a" : l.k === "-" ? "r" : "c") + (picked ? " is-pick" : "")}>
                <span className="cs-gut">{l.first && <Check state={picked ? "all" : "none"} onToggle={() => toggle([l.sec])} label={picked ? "Unpick these lines" : "Pick these lines"}/>}</span>
                <span className="isd-nums"><span>{l.o ?? ""}</span><span>{l.n ?? ""}</span></span>
                <span className="isd-sig">{l.k === "+" ? "+" : l.k === "-" ? "−" : ""}</span><span className="isd-txt">{l.s}</span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ a part split by whitespace-only lines (jj diff -w)
// Ralph's boxed hunk: under -w its changed runs are tied into ONE part (Story 10.41), with whitespace-only lines and
// a gap row between them. One checkbox, on the part's first changed line, takes every line of it — as the hunk
// header's box did. Hovering the box lights up every line it would take.
const W = (k, o, n, s, ws) => ({ k, o, n, s, ws });
const WS_TOP = [
  W(" ", 32, 46, "        headerSliverBuilder: (context, _) => ["),
  W(" ", 33, 47, "          ViegaExpandableAppBar(title: s.automationOverview_title, leading: const BackButton()),"),
  W(" ", 34, 48, "        ],"),
  W("-", 35, null, "        body: DynamicRestrictedWidth("),
  W("-", 36, null, "          child: automations == null"),
  W("+", null, 49, "        body: DynamicRestrictedWidth(child: _buildBody(context, automationsState)),"),
  W("+", null, 50, "      ),"),
  W("+", null, 51, "    );"),
  W("+", null, 52, "  }"),
  W("+", null, 53, ""),
  W("+", null, 54, "  Widget _buildBody(BuildContext context, AsyncValue<List<Automation>> automationsState) {"),
  W("+", null, 55, "    final automations = automationsState.value;"),
  W("+", null, 56, "    if (automations == null && automationsState.hasError) {"),
  W("+", null, 57, "      return ViegaListEmpty(type: .error, action: _retry);"),
  W("+", null, 58, "    }"),
  W("-", 37, null, "              ? const Center(child: CircularProgressIndicator())"),
  W("-", 38, null, "              : ListView("),
  W("+", null, 59, "    if (automations == null) return const Center(child: CircularProgressIndicator());"),
  W("+", null, 60, "    return ListView("),
  W(" ", 39, 61, "      // Leaves room for the floating action button.", 6),
  W(" ", 40, 62, "      padding: context.marginSymmetric(horizontal: true) + const EdgeInsets.only(bottom: SpacePrimitives.spacing96),", 6),
  W(" ", 41, 63, "      children: [", 6),
];
const WS_GAP = Array.from({ length: 13 }, (_, i) => W(" ", 42 + i, 64 + i,
  ["        for (final automation in automations)", "          Padding(", "            padding: const EdgeInsets.only(bottom: SpacePrimitives.spacing8),",
    "            child: AutomationCard(", "              automation: automation,", "              onTap: () => _open(context, automation),"][i % 6], 6));
const WS_END = [
  W(" ", 55, 77, "            ),", 6), W(" ", 56, 78, "          ),", 6), W(" ", 57, 79, "      ],", 6),
  W("-", 58, null, "                ),"), W("-", 59, null, "              ),"), W("-", 60, null, "            ),"),
  W(" ", 61, 80, "    );"), W(" ", 62, 81, "  }"), W(" ", 63, 82, "}"),
];
function WsHunk({ picks, toggle }) {
  const [open, setOpen] = useState(false);
  const [hot, setHot] = useState(false);
  const part = "wsPart", picked = picks.has(part);
  const firstChanged = WS_TOP.findIndex((l) => l.k !== " ");
  const line = (l, i, first) => {
    const mine = l.k !== " " || l.ws;
    const txt = l.ws
      ? (() => { const d = l.s.length - l.s.trimStart().length; // the two added spaces sit right before the text
        return <span className="isd-txt">{l.s.slice(0, d - 2)}<span className="cs-wsmark">{"  "}</span>{l.s.slice(d)}</span>; })()
      : <span className="isd-txt">{l.s}</span>;
    return (
      <div key={i} className={"isd-line cs-line k" + (l.k === "+" ? "a" : l.k === "-" ? "r" : "c") + (mine && picked ? " is-pick" : "") + (mine && hot && !picked ? " is-hot" : "")}>
        <span className="cs-gut">{first && <span onMouseEnter={() => setHot(true)} onMouseLeave={() => setHot(false)}>
          <Check state={picked ? "all" : "none"} onToggle={() => toggle([part])} label={picked ? "Unpick this part (all its lines)" : "Pick this part (all its lines)"}/></span>}</span>
        <span className="isd-nums"><span>{l.o ?? ""}</span><span>{l.n ?? ""}</span></span>
        <span className="isd-sig">{l.k === "+" ? "+" : l.k === "-" ? "−" : ""}</span>{txt}
      </div>
    );
  };
  return (
    <div className="isd-diff cs-code cs-wsdiff" tabIndex={-1}>
      <div className="isd-dbar">
        <span className="isd-dpath"><span className="isd-dname">automation_overview_page.dart</span><span className="isd-ddir">packages/logic_designer/lib/src/presentation/widgets/</span></span>
        <span className="cs-mode">Ignore all whitespace · jj diff -w</span>
      </div>
      <div className="isd-dbody">
        <div className="isd-dcontent is-wide">
          <div className="cs-gap"><span className="cs-gut"/><span className="cs-gnums"><button className="cs-gbtn" title="Show 20 lines above"><Ic n="up" s={14}/></button></span><span className="cs-gtxt">31 unchanged lines</span><button className="cs-gall">Show all</button></div>
          {WS_TOP.map((l, i) => line(l, "t" + i, i === firstChanged))}
          <div className={"cs-gap cs-wsgap" + (picked ? " is-pick" : hot ? " is-hot" : "")}>
            <span className="cs-gut"/><span className="cs-gnums"/>
            <span className="cs-gtxt">{open ? "13 lines with only whitespace changes" : "13 more lines with only whitespace changes"}</span>
            <button className="cs-gall cs-wsbtn" onClick={() => setOpen(!open)}>{open ? "Hide" : "Show"}</button>
          </div>
          {open && WS_GAP.map((l, i) => line(l, "g" + i, false))}
          {WS_END.map((l, i) => line(l, "e" + i, false))}
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ projects window excerpt
const GROUPS = [
  { name: "Privat", depth: 0, items: [
    { name: "dart-intellij-third-party", branch: "DartInlayHints", path: "~/development/projects/privat/dart-intellij-third-party", when: "12h ago" },
    { name: "jj", path: "~/development/projects/privat/jj", when: "yesterday" }] },
  { name: "Work", depth: 0, items: [] },
  { name: "adesso", depth: 1, items: [] },
  { name: "Viega", depth: 2, items: [
    { name: "TWMS-Flutter-App", open: true, branch: "main", path: "~/development/projects/Kunden/viega/TWMS-Flutter-App", when: "20m ago" }] },
  { name: "Archive", depth: 0, closed: true, items: [] },
];
function Projects() {
  const [closed, setClosed] = useState(() => new Set(["Archive"]));
  let hideBelow = null;
  return (
    <div className="cs-proj">
      {GROUPS.map((g) => {
        if (hideBelow !== null && g.depth > hideBelow) return null;
        hideBelow = closed.has(g.name) ? g.depth : null;
        const open = !closed.has(g.name);
        return (
          <React.Fragment key={g.name}>
            <button className="cs-group" style={{ paddingLeft: 10 + g.depth * 22 }}
              onClick={() => setClosed((c) => { const n = new Set(c); n.has(g.name) ? n.delete(g.name) : n.add(g.name); return n; })}>
              <Ic n={open ? "folderOpen" : "folder"} s={15}/><span>{g.name}</span>
            </button>
            {open && g.items.map((p) => (
              <div key={p.name} className="cs-prow" style={{ paddingLeft: 10 + (g.depth + 1) * 22 }}>
                <span className={"cs-dot" + (p.open ? " is-open" : "")}/>
                <div><div className="cs-pname">{p.name}{p.open && <span className="cs-popen">OPEN</span>}{p.branch && <span className="cs-pbr"><Ic n="branch" s={11}/>{p.branch}</span>}</div>
                  <div className="cs-ppath">{p.path} · {p.when}</div></div>
              </div>
            ))}
          </React.Fragment>
        );
      })}
    </div>
  );
}

// ------------------------------------------------------------ page
function App() {
  const [picks, setPicks] = useState(() => new Set(["test#0"]));
  const [focus, setFocus] = useState(FILES[1].path);
  const [force, setForce] = useState("none");
  const toggle = (secs) => setPicks((p) => {
    const n = new Set(p), on = !secs.every((s) => p.has(s));
    secs.forEach((s) => (on ? n.add(s) : n.delete(s)));
    return n;
  });
  return (
    <div className={"cs-win force-" + force}>
      <header className="cs-head">
        <b>Calm Inspector Study</b> — less on screen: folders say open or closed with their icon, checkboxes show only
        while the pointer is in their pane (picked or half-picked ones always), no +/− counts, no status letter for a
        plain change, no hunk header. The gaps between hunks open more context instead.
        <div className="cs-force">Pretend the pointer is in:
          <div className="isd-seg" role="radiogroup">
            {[["none", "nowhere"], ["files", "files"], ["code", "code"]].map(([k, t]) => (
              <button key={k} className={force === k ? "on" : ""} onClick={() => setForce(k)}>{t}</button>))}
          </div>
          <span>(real hover works too)</span>
        </div>
      </header>
      <section>
        <h2>1 · Inspector</h2>
        <div className="cs-insp">
          <FilesPane picks={picks} toggle={toggle} focus={focus} setFocus={setFocus}/>
          <DiffPane picks={picks} toggle={toggle}/>
        </div>
      </section>
      <section>
        <h2>2 · A part split by whitespace-only lines</h2>
        <p className="cs-note">Whitespace ignored: the hunk's changed runs are one part (they cut the same lines of the file).
          One checkbox on its first changed line picks all of it, like the hunk header's box did; hover the box to see
          every line it takes, the whitespace lines included.</p>
        <WsHunk picks={picks} toggle={toggle}/>
      </section>
      <section>
        <h2>3 · Projects window</h2>
        <p className="cs-note">The same folder rule: the icon opens and closes, the chevron is gone. Click a group.</p>
        <Projects/>
      </section>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
})();
