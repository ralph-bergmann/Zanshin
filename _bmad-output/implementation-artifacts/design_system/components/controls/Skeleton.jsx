import React from "react";

// Skeleton — "pending" placeholders whose shape is known: a bar, a card (240 × 62), a row (30px). A soft sweep every --dur-shimmer.
export function Skeleton({ kind = "bar", width = "100%", height = 10, radius = 4, className = "", style }) {
  if (kind === "card") return (
    <div className={("zs-skel-card " + className).trim()} style={style} aria-busy="true" aria-label="Loading change">
      <span className="zs-skel-line"><span className="zs-skel" style={{ width: 38, height: 9 }}></span><span className="zs-skel" style={{ width: "58%", height: 9 }}></span></span>
      <span className="zs-skel" style={{ width: "36%", height: 7 }}></span>
    </div>
  );
  if (kind === "row") return (
    <div className={("zs-skel-row " + className).trim()} style={style} aria-busy="true" aria-label="Loading">
      <span className="zs-skel" style={{ width: 14, height: 14, borderRadius: 3 }}></span>
      <span className="zs-skel" style={{ flex: 1, maxWidth: width, height: 8 }}></span>
      <span className="zs-skel" style={{ width: 34, height: 8 }}></span>
    </div>
  );
  return <span className={("zs-skel " + className).trim()} style={{ width, height, borderRadius: radius, ...style }} aria-hidden="true"></span>;
}
