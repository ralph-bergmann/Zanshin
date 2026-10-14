import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { ChangeId } from "./ChangeId.jsx";
import { AtBadge } from "./AtBadge.jsx";
import { BookmarkChip } from "./BookmarkChip.jsx";

// ChangeCard — one change in the graph. Detailed (62px): subject over meta. Compact (40px): one line.
// States: workingCopy (saffron, glow) · selected (moon ring) · immutable (◆, muted subject) · empty / undescribed (italic, dim) · root
// · dim · drop (rebase target) · dragging "src" | "from" · flash (just changed) · menuOpen (its ••• menu is showing)
// Hover affordances: the ••• button (onMenu) on the bottom edge; without bookmarks, a round bookmark button (onBookmark) on the top edge.
export function ChangeCard({
  id, subject, author, date, bookmarks = [], workingCopy, selected, hover, immutable, empty, root, conflict, merge,
  detailed = true, width, dim, drop, dragging, flash, menuOpen, onMenu, onBookmark, className = "", style, children, ...rest
}) {
  const quiet = !subject || root;
  const subj = <span className={"zs-card-subj" + (quiet ? " is-dim" : "")}>{root ? "root()" : subject || "(no description set)"}</span>;
  const flags = (
    <>
      {conflict && <span className="zs-card-flag is-conflict" title="conflict"><Icon name="conflict" size={12} /></span>}
      {merge && <span className="zs-card-flag" title="merge"><Icon name="merge" size={12} /></span>}
    </>
  );
  const cls = ["zs-card", !detailed && "is-compact", workingCopy && "is-wc", selected && "is-sel", hover && "is-hover", immutable && "is-immutable", root && "is-root",
    dim && "is-dim", drop && "is-drop", dragging && "is-drag-" + dragging, flash && "is-flash", menuOpen && "is-menu", className].filter(Boolean).join(" ");
  const cid = <ChangeId id={id} length={detailed && !workingCopy ? 8 : 5} immutable={immutable && !root} />;
  const stop = (e) => e.stopPropagation();
  return (
    <div role="button" tabIndex={0} aria-label={(workingCopy ? "Working copy, " : "") + (subject || "no description")} className={cls} style={{ width, ...style }} data-change={id} {...rest}>
      {detailed ? (
        <>
          <div className="zs-card-line">{subj}</div>
          <div className="zs-card-line zs-card-meta">
            {workingCopy && <AtBadge />}
            {cid}
            {author && <span className="zs-card-meta-t au">{author.split(" ")[0]}</span>}
            {date && <span className="zs-card-meta-t">{date}</span>}
            {empty && <span className="zs-card-meta-t em">empty</span>}
            {flags}
          </div>
        </>
      ) : (
        <div className="zs-card-line">
          {workingCopy && <AtBadge />}
          {cid}
          {subj}
          {flags}
        </div>
      )}
      {bookmarks.length > 0 && !root && <BookmarkChip name={bookmarks[0]} more={bookmarks.length - 1} />}
      {!bookmarks.length && !root && onBookmark && (
        <button type="button" className="zs-card-bmadd" aria-label="Bookmarks" title="Bookmarks" onClick={(e) => { stop(e); onBookmark(e); }} onPointerDown={stop}>
          <Icon name="bookmark" size={11} />
        </button>
      )}
      {onMenu && (
        <button type="button" className="zs-card-more" aria-label="Actions" aria-haspopup="menu" aria-expanded={!!menuOpen} title="Actions (or right-click the card)"
          onClick={(e) => { stop(e); onMenu(e); }} onDoubleClick={stop} onPointerDown={stop}>
          <Icon name="more-bold" size={12} />
        </button>
      )}
      {children}
    </div>
  );
}
