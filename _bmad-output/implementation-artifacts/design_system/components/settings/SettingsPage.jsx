import React from "react";
import { Icon } from "../brand/Icon.jsx";

// SettingsPage — a page inside a Settings tab, reached from a navigation row (SettingsRow onOpen). The back button names the tab it
// returns to ("‹ MyApp"), then the title (17/600) and one sentence on what the page decides, then its groups. The window title becomes
// the page's name; the tabs, the scope line and the footer stay. Changes apply at once, as everywhere in Settings. ⌘[ goes back.
export function SettingsPage({ back, onBack, title, intro, children, className = "" }) {
  const onKey = (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "[" && onBack) { e.preventDefault(); onBack(); } };
  return (
    <div className={("zs-setpage " + className).trim()} onKeyDown={onKey}>
      <div className="zs-setpage-top">
        <button type="button" className="zs-setpage-back" onClick={onBack} aria-label={typeof back === "string" ? "Back to " + back : undefined} title="Back — ⌘["><Icon name="chevron-left" size="sm" />{back}</button>
      </div>
      <div className="zs-setpage-intro">
        <h2 className="zs-setpage-title">{title}</h2>
        {intro && <p className="zs-setpage-p">{intro}</p>}
      </div>
      {children}
    </div>
  );
}
