/* global React, ReactDOM */
// App shell for "JJ Desktop Client.html" — shared components live in app-shared.jsx
(() => {
const { useState, useEffect, useRef, useMemo, useCallback } = React;
// ============================================================
// TWEAK DEFAULTS
// ============================================================
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "system",
  "diffMode": "inline",
  "density": "compact",
  "showFiles": true,
  "bookmarkLabels": "legend",
  "addButtons": "menu",
  "laneOrder": "optimized",
  "crossings": "bridge",
  "hoverFocus": true,
  "gapMarker": "break",
  "gapCount": false
}/*EDITMODE-END*/;
const URLQ = new URLSearchParams(location.search);
const URL_TWEAKS = Object.fromEntries([["theme", URLQ.get("th") || URLQ.get("theme")], ["gapMarker", URLQ.get("gap")], ["gapCount", URLQ.has("count") ? URLQ.get("count") === "1" : null]].filter(([, v]) => v != null));

// ============================================================
// APP
// ============================================================
const DEFAULT_WIDTHS = {
  __history__: 420,
  "main": 340,
  "develop": 340,
  "feature/new-ui": 340,
  "fix/ios-keyboard": 320,
  "exp/riverpod-3": 320,
};

function App() {
  const [t, setTweak] = useTweaks({ ...TWEAK_DEFAULTS, ...URL_TWEAKS });
  const [activeProject, setActiveProject] = useState("flutter-app");
  const [homeTree, setHomeTree] = useState(() => window.HOME_TREE);
  const [homeOpen, setHomeOpen] = useState(!URLQ.has("embed")); // opens automatically on app start
  const [activeProjectId, setActiveProjectId] = useState(window.ACTIVE_PROJECT_ID || "p_myapp");
  // Slot-based model: each slot holds 1+ branches (stacked vertically).
  // mergeGroup ID groups adjacent slots into a virtual merge cluster.
  const [slots, setSlots] = useState(() =>
    window.OPEN_COLUMNS.map((b, i) => ({ id: "s" + (i + 1), branches: [b], mergeGroup: null }))
  );
  const [columnWidths, setColumnWidths] = useState({ ...DEFAULT_WIDTHS });
  const [selected, setSelected] = useState(null);
  // checkedOut: which commit is the active working copy (`@`). Initialized from data.
  const initialCheckedOut = useMemo(() => {
    for (const b of (window.BOOKMARKS || [])) {
      const list = window.COMMITS_BY_BRANCH[b.name] || [];
      const c = list.find(x => x.isWorkingCopy);
      if (c) return { source: b.name, changeId: c.changeId, commit: c };
    }
    return null;
  }, []);
  const [checkedOut, setCheckedOut] = useState(initialCheckedOut);
  // editMeta: when true, the open detail panel renders the EditPanel (subject/desc editor).
  const [editMeta, setEditMeta] = useState(false);
  const [hoveredId, setHoveredId] = useState(null);
  const [dragName, setDragName] = useState(null);     // branch being dragged
  const [dragSlot, setDragSlot] = useState(null);     // slot being reordered
  const [dropTarget, setDropTarget] = useState(null); // { kind: 'slot-top'|'slot-bot'|'slot-between'|'slot-edge'|'merge', slotId?, idx?, side? }
  const [flyout, setFlyout] = useState(null);
  const flyoutTimer = useRef(null);
  const [leftPanel, setLeftPanel] = useState("history"); // history | branches | reviews | undo

  // Flatten branches for sidebar "open" highlighting + tags
  const openBranches = useMemo(() => slots.flatMap(s => s.branches), [slots]);

  // hover/click handler for flyout
  const handleFlyoutSet = (id, source) => {
    if (flyoutTimer.current) { clearTimeout(flyoutTimer.current); flyoutTimer.current = null; }
    if (source === "click") {
      setFlyout(prev => prev === id ? null : id);
    } else {
      setFlyout(id);
    }
  };
  const onFlyoutLeave = () => {
    if (flyoutTimer.current) clearTimeout(flyoutTimer.current);
    flyoutTimer.current = setTimeout(() => setFlyout(null), 600);
  };
  const onFlyoutEnter = () => {
    if (flyoutTimer.current) { clearTimeout(flyoutTimer.current); flyoutTimer.current = null; }
  };

  // Theme (light / dark / system)
  useEffect(() => {
    if (t.theme === "system") {
      const mql = window.matchMedia("(prefers-color-scheme: dark)");
      const apply = () => { document.documentElement.dataset.theme = mql.matches ? "dark" : "light"; };
      apply();
      mql.addEventListener("change", apply);
      return () => mql.removeEventListener("change", apply);
    }
    document.documentElement.dataset.theme = t.theme;
  }, [t.theme]);

  useEffect(() => { document.documentElement.dataset.density = t.density; }, [t.density]);

  // When the selected commit changes, exit metadata edit mode.
  useEffect(() => { setEditMeta(false); }, [selected?.changeId]);

  // Esc: exits metadata edit first, then closes the detail panel.
  useEffect(() => {
    const h = (e) => {
      if (e.key !== "Escape") return;
      if (editMeta) { setEditMeta(false); return; }
      if (selected) setSelected(null);
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [selected, editMeta]);

  // jj edit <change> — move the working copy to this commit.
  const onCheckout = useCallback((data) => {
    setCheckedOut(data);
  }, []);
  const onStartEditMeta = useCallback(() => setEditMeta(true), []);
  const onCancelEditMeta = useCallback(() => setEditMeta(false), []);

  const toggleColumn = (name) => {
    setSlots(prev => {
      const isOpen = prev.some(s => s.branches.includes(name));
      if (isOpen) {
        if (selected?.source === name) setSelected(null);
        // Remove from wherever it lives; drop now-empty slots.
        return prev.flatMap(slot => {
          const next = slot.branches.filter(b => b !== name);
          return next.length ? [{ ...slot, branches: next }] : [];
        });
      }
      // Add as new slot at the end.
      return [...prev, { id: "s_" + name + "_" + Date.now(), branches: [name], mergeGroup: null }];
    });
  };

  const closeBranch = (name) => {
    setSlots(prev => prev.flatMap(slot => {
      const next = slot.branches.filter(b => b !== name);
      return next.length ? [{ ...slot, branches: next }] : [];
    }));
    if (selected?.source === name) setSelected(null);
  };

  // Insert a branch into an existing slot at a position (top/bottom/index)
  const addBranchToSlot = (slotId, branchName, position = "bottom") => {
    setSlots(prev => {
      const cleaned = prev.flatMap(slot => {
        const next = slot.branches.filter(b => b !== branchName);
        return next.length ? [{ ...slot, branches: next }] : [];
      });
      return cleaned.map(slot => {
        if (slot.id !== slotId) return slot;
        const idx = position === "top" ? 0 :
                    position === "bottom" ? slot.branches.length :
                    typeof position === "number" ? position : slot.branches.length;
        return { ...slot, branches: [...slot.branches.slice(0, idx), branchName, ...slot.branches.slice(idx)] };
      });
    });
  };

  // Insert a NEW slot at index, possibly with a branch
  const insertSlotAt = (index, branchName) => {
    setSlots(prev => {
      const cleaned = prev.flatMap(slot => {
        const next = slot.branches.filter(b => b !== branchName);
        return next.length ? [{ ...slot, branches: next }] : [];
      });
      const newSlot = { id: "s_" + branchName + "_" + Date.now(), branches: [branchName], mergeGroup: null };
      return [...cleaned.slice(0, index), newSlot, ...cleaned.slice(index)];
    });
  };

  // Move slot (drag-reorder)
  const moveSlot = (fromId, toIdx) => {
    setSlots(prev => {
      const fromIdx = prev.findIndex(s => s.id === fromId);
      if (fromIdx === -1) return prev;
      const item = prev[fromIdx];
      const without = prev.filter((_, i) => i !== fromIdx);
      const adjustedIdx = toIdx > fromIdx ? toIdx - 1 : toIdx;
      return [...without.slice(0, adjustedIdx), item, ...without.slice(adjustedIdx)];
    });
  };

  // Toggle merge with right neighbor: assign both slots the same mergeGroup
  const toggleMergeWithRight = (slotId) => {
    setSlots(prev => {
      const idx = prev.findIndex(s => s.id === slotId);
      if (idx === -1 || idx >= prev.length - 1) return prev;
      const me = prev[idx];
      const right = prev[idx + 1];
      // If they share a group, break me out of it
      if (me.mergeGroup && me.mergeGroup === right.mergeGroup) {
        return prev.map((s, i) => i === idx ? { ...s, mergeGroup: null } : s);
      }
      // Otherwise: merge them into one group
      const group = me.mergeGroup || right.mergeGroup || ("m_" + Date.now());
      return prev.map((s, i) => {
        if (i === idx || i === idx + 1) return { ...s, mergeGroup: group };
        return s;
      });
    });
  };

  // ── Resize ────────────────────────────────
  const startResize = (e, key) => {
    e.preventDefault();
    const startX = e.clientX;
    const startW = columnWidths[key] || 360;
    const onMove = (ev) => {
      const newW = Math.max(240, Math.min(900, startW + ev.clientX - startX));
      setColumnWidths(w => ({ ...w, [key]: newW }));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  // Build clusters (consecutive slots with same mergeGroup get rendered together)
  const clusters = useMemo(() => {
    const out = [];
    let i = 0;
    while (i < slots.length) {
      const s = slots[i];
      if (s.mergeGroup) {
        const grp = [];
        while (i < slots.length && slots[i].mergeGroup === s.mergeGroup) {
          grp.push(slots[i]);
          i++;
        }
        out.push({ kind: "merge", group: s.mergeGroup, slots: grp });
      } else {
        out.push({ kind: "solo", slots: [s] });
        i++;
      }
    }
    return out;
  }, [slots]);

  const onBranchDragStart = (e, name) => {
    e.dataTransfer.setData("text/plain", name);
    e.dataTransfer.effectAllowed = "move";
    setDragName(name);
  };

  const onSlotHeaderDragStart = (e, slotId) => {
    e.dataTransfer.setData("application/x-slot", slotId);
    e.dataTransfer.effectAllowed = "move";
    setDragSlot(slotId);
  };

  const onDropTarget = (e, target) => {
    e.preventDefault();
    setDropTarget(null);
    setDragName(null);
    setDragSlot(null);

    const name = e.dataTransfer.getData("text/plain");
    const slotId = e.dataTransfer.getData("application/x-slot");

    if (slotId) {
      // Slot reorder
      if (target.kind === "slot-edge") {
        moveSlot(slotId, target.idx);
      }
      return;
    }

    if (name && window.BOOKMARKS.find(b => b.name === name)) {
      if (target.kind === "slot-top")      addBranchToSlot(target.slotId, name, "top");
      else if (target.kind === "slot-bot") addBranchToSlot(target.slotId, name, "bottom");
      else if (target.kind === "slot-between") addBranchToSlot(target.slotId, name, target.idx);
      else if (target.kind === "slot-edge") insertSlotAt(target.idx, name);
      else if (target.kind === "merge")   {
        // Add to merge group as a new slot
        const groupSlots = slots.filter(s => s.mergeGroup === target.group);
        const lastIdxInGroup = slots.findIndex(s => s === groupSlots[groupSlots.length - 1]);
        // Insert after the last slot in this merge group
        setSlots(prev => {
          const cleaned = prev.flatMap(slot => {
            const next = slot.branches.filter(b => b !== name);
            return next.length ? [{ ...slot, branches: next }] : [];
          });
          const insertIdx = cleaned.findIndex(s => s.mergeGroup === target.group) + groupSlots.length;
          const newSlot = { id: "s_" + name + "_" + Date.now(), branches: [name], mergeGroup: target.group };
          return [...cleaned.slice(0, insertIdx), newSlot, ...cleaned.slice(insertIdx)];
        });
      }
    }
  };
  const onDropOver = (e, target) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    setDropTarget(target);
  };
  const onDragLeaveAny = () => setDropTarget(null);
  const onDragEnd = () => {
    setDragName(null);
    setDragSlot(null);
    setDropTarget(null);
  };

  const dragActive = !!(dragName || dragSlot);

  const activeProjectNode = useMemo(() => {
    const all = flattenAll(homeTree);
    return all.find(x => x.node.id === activeProjectId)?.node || null;
  }, [homeTree, activeProjectId]);

  return (
    <WindowChrome theme={t.theme} onSetTheme={(v) => setTweak("theme", v)}>
      <div className="app-grid" onMouseLeave={() => { if (flyout) onFlyoutLeave(); }}>
        <NavRail
          activePanel={leftPanel}
          onSelectPanel={setLeftPanel}
          onOpenHome={() => setHomeOpen(true)}
          homeOpen={homeOpen}
          activeProjectName={activeProjectNode?.name}
        />
        <main className="main-area">
          <GraphWorkspace t={t} setTweak={setTweak} leftPanel={leftPanel} onCloseLeft={() => setLeftPanel("history")}/>
        </main>
      </div>
      <StatusBar openCount={slots.length}/>
      <button className="help-fab" title="Help">?</button>

      {flyout && (
        <Flyout
          top={82}
          onClose={() => setFlyout(null)}
          onMouseEnter={onFlyoutEnter}
          onMouseLeave={onFlyoutLeave}
        >
          {flyout === "branches" && (
            <BranchesFlyout
              openColumns={openBranches}
              onToggle={(name) => { toggleColumn(name); }}
              onClose={() => setFlyout(null)}
            />
          )}
          {flyout === "reviews"    && <PlaceholderFlyout title="Reviews"     onClose={() => setFlyout(null)}/>}
          {flyout === "undo"       && <PlaceholderFlyout title="Undo Timeline" onClose={() => setFlyout(null)}/>}
        </Flyout>
      )}

      <TweaksPanel title="Tweaks">
        <TweakSection label="Display"/>
        <TweakRadio
          label="Density" value={t.density}
          onChange={v => setTweak("density", v)}
          options={[
            { value: "compact",  label: "Compact" },
            { value: "balanced", label: "Balanced" },
            { value: "comfy",    label: "Comfy" },
          ]}
        />
        <TweakSection label="Graph"/>
        <TweakRadio
          label="Bookmark labels" value={t.bookmarkLabels}
          onChange={v => setTweak("bookmarkLabels", v)}
          options={[{ value: "legend", label: "Always" }, { value: "hover", label: "On hover" }]}
        />
        <TweakSelect label="New change" value={t.addButtons} onChange={v => setTweak("addButtons", v)}
          options={[{ value: "menu", label: "More button — icon fan" }, { value: "edges", label: "+ on card edges" }, { value: "context", label: "Right-click only" }, { value: "both", label: "More button + right-click" }]}/>
        <TweakRadio label="Lane order" value={t.laneOrder} onChange={v => setTweak("laneOrder", v)}
          options={[{ value: "optimized", label: "Min. crossings" }, { value: "greedy", label: "Greedy" }]}/>
        <TweakRadio label="Crossings" value={t.crossings} onChange={v => setTweak("crossings", v)}
          options={[{ value: "bridge", label: "Bridge gap" }, { value: "plain", label: "Plain" }]}/>
        <TweakToggle label="Hover: focus path" value={t.hoverFocus} onChange={v => setTweak("hoverFocus", v)}/>
        <TweakSection label="Hidden history"/>
        <TweakRadio label="Gap marker" value={t.gapMarker} onChange={v => setTweak("gapMarker", v)}
          options={[{ value: "dots", label: "Dots" }, { value: "break", label: "Break" }, { value: "pill", label: "Pill" }]}/>
        <TweakToggle label="Show hidden count" value={t.gapCount} onChange={v => setTweak("gapCount", v)}/>
        <TweakSection label="Diff"/>
        <TweakRadio
          label="Default mode" value={t.diffMode}
          onChange={v => setTweak("diffMode", v)}
          options={[{ value: "inline", label: "Inline" }, { value: "split", label: "Split" }]}
        />
        <TweakToggle label="Show changed files" value={t.showFiles} onChange={v => setTweak("showFiles", v)}/>
      </TweaksPanel>

      {homeOpen && (
        <HomeDialog
          tree={homeTree}
          setTree={setHomeTree}
          activeProjectId={activeProjectId}
          onOpenProject={(p) => { setActiveProjectId(p.id); setHomeOpen(false); }}
          onClose={() => setHomeOpen(false)}
          canClose={true}
        />
      )}
    </WindowChrome>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
})();
