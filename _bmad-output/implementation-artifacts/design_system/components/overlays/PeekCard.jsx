import React from "react";
import { HatchSwatch } from "../graph/HatchSwatch.jsx";

// PeekCard — the hover card beside a change (after 450ms): subject, description, id · commit · author · date, file and line counts, how to act on it.
// immutable: an eyebrow above the subject — the swatch + IMMUTABLE (caps), then the reason (11.5, --text-dim); the reason drops to its own
// line as a whole when it doesn't fit and ellipsizes beyond that. The hint then leaves out "Double-click: jj edit".
export function PeekCard({ id = "", commit, subject, description, author, date, files, added = 0, removed = 0, hint, immutable = false, immutableWhy, className = "", style }) {
  const f = files || {};
  const has = (f.a || 0) + (f.m || 0) + (f.d || 0) > 0;
  return (
    <div className={("zs-peek " + className).trim()} style={style}>
      {immutable && (
        <div className="zs-peek-imm">
          <span className="zs-peek-imm-l"><HatchSwatch />Immutable</span>
          {immutableWhy && <span className="zs-peek-imm-why" title={immutableWhy}>{immutableWhy}</span>}
        </div>
      )}
      <div className="zs-peek-subj">{subject}</div>
      {description && <div className="zs-peek-desc">{description}</div>}
      <div className="zs-peek-meta">
        {id && <span className="zs-cid"><b>{id.slice(0, 2)}</b>{id.slice(2, 8)}</span>}
        {commit && <span className="zs-peek-dim">{commit}</span>}
        {author && <span>{author}</span>}
        {date && <span className="zs-peek-dim">{date}</span>}
      </div>
      {files !== undefined && (has ? (
        <div className="zs-peek-stats">
          <span className="fa" title="files added">A {f.a || 0}</span>
          <span className="fm" title="files modified">M {f.m || 0}</span>
          <span className="fd" title="files deleted">D {f.d || 0}</span>
          <span className="zs-peek-lines"><span className="la">+{added}</span><span className="lr">−{removed}</span></span>
        </div>
      ) : <div className="zs-peek-stats zs-peek-dim">No file changes</div>)}
      {hint && <div className="zs-peek-hint">{hint}</div>}
    </div>
  );
}
