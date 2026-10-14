import React from "react";

// StackCard — a linear run of ≥ 2 changes (one parent, one child, no bookmark, not @) folded into one card.
// The count bubble leads; the meta line shows the range newest‥oldest (from = top member, to = bottom member).
export function StackCard({ count, subject, from = "", to = "", author, date, detailed = true, width, className = "", style, ...rest }) {
  const cls = ["zs-card is-stack", !detailed && "is-compact", className].filter(Boolean).join(" ");
  return (
    <div role="button" tabIndex={0} className={cls} style={{ width, ...style }} title={count + " changes — click to expand"} {...rest}>
      <div className="zs-card-line">
        <span className="zs-stack-n">{count}</span>
        <span className="zs-card-subj">{subject}</span>
      </div>
      {detailed && (
        <div className="zs-card-line zs-card-meta">
          <span className="zs-cid"><b>{from.slice(0, 2)}</b>{from.slice(2, 5)}<span className="zs-range-sep">‥</span><b>{to.slice(0, 2)}</b>{to.slice(2, 5)}</span>
          {author && <span className="zs-card-meta-t au">{author}</span>}
          {date && <span className="zs-card-meta-t">{date}</span>}
        </div>
      )}
    </div>
  );
}
