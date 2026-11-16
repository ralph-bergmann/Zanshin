import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { ChangeId } from "./ChangeId.jsx";
import { AtBadge, WorkspaceTag } from "./AtBadge.jsx";
import { BookmarkChip } from "./BookmarkChip.jsx";

// ChangeCard — one change in the graph. Detailed (62px): subject over meta. Compact (40px): one line.
// States: workingCopy (saffron, glow) · selected (moon ring) · immutable (hatched, muted subject — no ◆, no colour; the hatch stays on hover, selection, open menu and drop) · empty / undescribed (italic, dim) · root
// · dim · drop (rebase target) · dragging "src" | "from" · flash (just changed) · menuOpen (its card menu is showing — right-click, the
// context-menu key, ⇧F10 or VoiceOver's "Show menu"; there is no ••• button)
// Hover affordance: without bookmarks, a round bookmark button (onBookmark) on the top edge.
// tags: the tag legend on the bottom edge, right — the bookmark pill's shape, calmer (tag glyph, dim regular text, a plain border),
// at most half the card less 34px so the line to the parent stays free; with onTags a click opens the tag popover.
// workspaces: the workspaces whose working copy is this commit — pass them only when the repo has two or more (jj prints no marker
// with one). Ours (ownWorkspace) is the saffron name@ badge; the others are quiet name@ tags, two at most, then +N (its title lists them).
export function ChangeCard({
  id, subject, author, date, bookmarks = [], tags = [], workspaces, ownWorkspace, workingCopy, selected, hover, immutable, empty, root, conflict, merge,
  detailed = true, width, dim, drop, dragging, flash, menuOpen, onBookmark, onTags, className = "", style, children, ...rest
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
  const cid = <ChangeId id={id} length={detailed && !workingCopy ? 8 : 5} />;
  const stop = (e) => e.stopPropagation();
  const others = (workspaces || []).filter((w) => w !== ownWorkspace).sort();
  const named = workspaces && workspaces.length > 0;
  const tagSlash = tags.length ? tags[0].lastIndexOf("/") : -1;
  const at = (
    <>
      {workingCopy && <AtBadge name={named ? ownWorkspace : undefined} />}
      {others.slice(0, 2).map((w) => <WorkspaceTag key={w} name={w} />)}
      {others.length > 2 && <WorkspaceTag more={others.length - 2} title={others.slice(2).map((w) => w + "@").join(" · ")} />}
    </>
  );
  return (
    <div role="button" tabIndex={0} aria-label={(workingCopy ? "Working copy" + (named ? " of " + ownWorkspace : "") + ", " : "") + (others.length ? "working copy of " + others.join(", ") + ", " : "") + (immutable && !root ? "Immutable, " : "") + (subject || "no description")} className={cls} style={{ width, ...style }} data-change={id} {...rest}>
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
      {tags.length > 0 && !root && (
        <span className="zs-bm zs-card-tags" role={onTags ? "button" : undefined} tabIndex={onTags ? 0 : undefined}
          aria-label={"Tags: " + tags.join(", ")} title={"Tags: " + tags.join(", ")}
          onClick={onTags && ((e) => { stop(e); onTags(e); })} onDoubleClick={stop} onPointerDown={stop}>
          <Icon name="tag" size="sm" />
          {tagSlash >= 0 && <span className="zs-bm-rest is-prefix">{tags[0].slice(0, tagSlash + 1)}</span>}
          <span className="zs-bm-main">{tags[0].slice(tagSlash + 1)}</span>
          {tags.length > 1 && <span className="zs-bm-more">+{tags.length - 1}</span>}
        </span>
      )}
      {children}
    </div>
  );
}
