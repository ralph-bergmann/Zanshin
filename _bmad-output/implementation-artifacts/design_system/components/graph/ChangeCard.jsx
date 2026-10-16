import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { ChangeId } from "./ChangeId.jsx";
import { AtBadge, WorkspaceTag } from "./AtBadge.jsx";
import { BookmarkChip } from "./BookmarkChip.jsx";

// ChangeCard — one change in the graph. Detailed (62px): subject over meta. Compact (40px): one line.
// States: workingCopy (saffron, glow) · selected (moon ring) · immutable (◆, muted subject) · empty / undescribed (italic, dim) · root
// · dim · drop (rebase target) · dragging "src" | "from" · flash (just changed) · menuOpen (its ••• menu is showing)
// Hover affordances: the ••• button (onMenu) on the bottom edge; without bookmarks, a round bookmark button (onBookmark) on the top edge.
// workspaces: the workspaces whose working copy is this commit — pass them only when the repo has two or more (jj prints no marker
// with one). Ours (ownWorkspace) is the saffron name@ badge; the others are quiet name@ tags, two at most, then +N (its title lists them).
export function ChangeCard({
  id, subject, author, date, bookmarks = [], workspaces, ownWorkspace, workingCopy, selected, hover, immutable, empty, root, conflict, merge,
  detailed = true, width, dim, drop, dragging, flash, menuOpen, onMenu, onBookmark, className = "", style, children, ...rest
}) {
  const quiet = !subject || root;
  const subj = <span className={"zs-card-subj" + (quiet ? " is-dim" : "")}>{root ? "root()" : subject || "(no description set)"}</span>;
  const flags = (
    <>
      {conflict && <span className="zs-card-flag is-conflict" title="conflict"><Icon name="conflict" size="sm" /></span>}
      {merge && <span className="zs-card-flag" title="merge"><Icon name="merge" size="sm" /></span>}
    </>
  );
  const cls = ["zs-card", !detailed && "is-compact", workingCopy && "is-wc", selected && "is-sel", hover && "is-hover", immutable && "is-immutable", root && "is-root",
    dim && "is-dim", drop && "is-drop", dragging && "is-drag-" + dragging, flash && "is-flash", menuOpen && "is-menu", className].filter(Boolean).join(" ");
  const cid = <ChangeId id={id} length={detailed && !workingCopy ? 8 : 5} immutable={immutable && !root} />;
  const stop = (e) => e.stopPropagation();
  const others = (workspaces || []).filter((w) => w !== ownWorkspace).sort();
  const named = workspaces && workspaces.length > 0;
  const at = (
    <>
      {workingCopy && <AtBadge name={named ? ownWorkspace : undefined} />}
      {others.slice(0, 2).map((w) => <WorkspaceTag key={w} name={w} />)}
      {others.length > 2 && <WorkspaceTag more={others.length - 2} title={others.slice(2).map((w) => w + "@").join(" · ")} />}
    </>
  );
  return (
    <div role="button" tabIndex={0} aria-label={(workingCopy ? "Working copy" + (named ? " of " + ownWorkspace : "") + ", " : "") + (others.length ? "working copy of " + others.join(", ") + ", " : "") + (subject || "no description")} className={cls} style={{ width, ...style }} data-change={id} {...rest}>
      {detailed ? (
        <>
          <div className="zs-card-line">{subj}</div>
          <div className="zs-card-line zs-card-meta">
            {at}
            {cid}
            {author && <span className="zs-card-meta-t au">{author.split(" ")[0]}</span>}
            {date && <span className="zs-card-meta-t">{date}</span>}
            {empty && <span className="zs-card-meta-t em">empty</span>}
            {flags}
          </div>
        </>
      ) : (
        <div className="zs-card-line">
          {at}
          {cid}
          {subj}
          {flags}
        </div>
      )}
      {bookmarks.length > 0 && !root && <BookmarkChip name={bookmarks[0]} more={bookmarks.length - 1} />}
      {!bookmarks.length && !root && onBookmark && (
        <button type="button" className="zs-card-bmadd" aria-label="Bookmarks" title="Bookmarks" onClick={(e) => { stop(e); onBookmark(e); }} onPointerDown={stop}>
          <Icon name="bookmark" size="sm" />
        </button>
      )}
      {onMenu && (
        <button type="button" className="zs-card-more" aria-label="Actions" aria-haspopup="menu" aria-expanded={!!menuOpen} title="Actions (or right-click the card)"
          onClick={(e) => { stop(e); onMenu(e); }} onDoubleClick={stop} onPointerDown={stop}>
          <Icon name="more" size="sm" />
        </button>
      )}
      {children}
    </div>
  );
}
