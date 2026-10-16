import * as React from "react";

/** Hover card for a change (graph peek, stack rows, gap callouts). States: shown after --delay-peek · flipped left near the right edge. */
export interface PeekCardProps {
  /** change id (first 2 bold, 8 shown) */
  id?: string;
  /** commit hash, dim mono */
  commit?: string;
  subject: React.ReactNode;
  description?: string;
  author?: string;
  date?: string;
  /** file counts; pass {} for "No file changes", omit to hide the stats row */
  files?: { a?: number; m?: number; d?: number };
  added?: number;
  removed?: number;
  /** how to act: "Click: details · Double-click: jj edit · Drag: onto another change · Right-click: actions" */
  hint?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function PeekCard(props: PeekCardProps): JSX.Element;
