import React from "react";
import { Icon } from "../brand/Icon.jsx";

// Ticket ids lead (feature/ZAN-412_onboarding-swipe → ZAN-412 · onboarding-swipe); otherwise the last path segment does.
function zsSplitBookmark(name) {
  const [base, remote] = name.split("@");
  const m = base.match(/[A-Z][A-Z0-9]+-\d+/);
  if (m) return { main: m[0], rest: base.slice(m.index + m[0].length).replace(/^[_\-/.]+/, ""), remote };
  const seg = base.split("/");
  if (seg.length > 1) return { prefix: seg.slice(0, -1).join("/") + "/", main: seg[seg.length - 1], remote };
  return { main: base, remote };
}
const ZS_BM_STATE = { synced: "in sync with origin", ahead: "ahead of origin", behind: "behind origin", local: "local only", remote: "remote only", diverged: "diverged from origin" };
const zsBmShort = (state, ahead) => state === "ahead" ? "↑" + (ahead || 1) : state === "synced" ? "✓" : state === "diverged" ? "↕" : state === "behind" ? "↓" : state;

// BookmarkChip — legend: the pill on a card's top edge (ticket id leads) · tag: full name + short sync state (inspector), draggable onto another change
export function BookmarkChip({ name, more = 0, state, ahead, variant = "legend", title, className = "", ...rest }) {
  if (variant === "tag") {
    return (
      <span className={("zs-bm is-tag " + className).trim()} title={title || (state ? name + " — " + (ZS_BM_STATE[state] || state) : name)} {...rest}>
        <Icon name="bookmark-filled" size={11} />
        <span className="zs-bm-name">{name}</span>
        {state && <span className={"zs-bm-state s-" + state}>{zsBmShort(state, ahead)}</span>}
      </span>
    );
  }
  const b = zsSplitBookmark(name);
  return (
    <span className={("zs-bm " + className).trim()} title={title || name} {...rest}>
      <Icon name="bookmark-filled" size={12} />
      {b.prefix && <span className="zs-bm-rest is-prefix">{b.prefix}</span>}
      <span className="zs-bm-main">{b.main}</span>
      {b.rest && <span className="zs-bm-rest">{b.rest}</span>}
      {b.remote && <span className="zs-bm-rest">@{b.remote}</span>}
      {more > 0 && <span className="zs-bm-more">+{more}</span>}
    </span>
  );
}
