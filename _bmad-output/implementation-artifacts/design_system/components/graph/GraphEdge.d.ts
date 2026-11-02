import * as React from "react";

type Pt = [number, number];
type Rect = { x: number; y: number; w: number; h: number };

/** One parent → child line, rendered inside an <svg>. States: rest · hover · @ path · gap (dashed + cuts) · dim · hidden while the layout moves. */
export interface GraphEdgeProps {
  /** the line's exit on the parent's top edge — centre for a lone (not merge-up) or straight line, else GraphPorts.exits */
  from?: Pt;
  /** the line's entry on the child's bottom edge — centre for a lone or straight line, else GraphPorts.entries */
  to?: Pt;
  /** explicit orthogonal polyline (parent → child) instead of from/to — e.g. a gutter detour */
  points?: Pt[];
  /** y of the horizontal run (its track) for lane changes; default midway */
  bend?: number;
  /** wc = the path from @ down to trunk (saffron, 2.25px, glow) · hover · dim */
  kind?: "normal" | "wc" | "hover" | "dim";
  /** elbow radius, default 10 */
  radius?: number;
  /** the revset hides changes in between: dashed, with the break mark */
  gap?: boolean;
  /** where the break mark goes (a hidden merge's shared stem); false = dashed without a mark; default: first stretch with room, from the child */
  gapAt?: { x: number; y: number; dir: "v" | "h" } | false;
  /** bridges: rectangles where this line breaks for a crossing (GraphPorts.bridge) */
  cuts?: Rect[];
}
export declare function GraphEdge(props: GraphEdgeProps): JSX.Element;

/** End of visible history under a card: dashed stub, cut mark, "~ elided". */
export interface GraphEndProps { x: number; y: number; label?: string; kind?: "normal" | "wc" | "hover" | "dim"; }
export declare function GraphEnd(props: GraphEndProps): JSX.Element;

/** The router's port and line rules (graph-layout.jsx), as numbers and helpers. */
export declare const GraphPorts: {
  /** the port fan at both card edges (Story 10.30) */
  ENTRY: { first: 24; step: 16; min: 8; inset: 18 };
  /** px of visible line a break keeps to the next bend or card */
  CUT_CLEAR: 12;
  TRACK: { min: 3.5; max: 6 };
  BAND_INSET: 12;
  RADIUS: 10;
  /** offsets from the card centre for m lines leaving one side of a parent's top edge, innermost first */
  exits(m: number, cardW: number): number[];
  /** offsets from the card centre for the other parents entering one side of a child's bottom edge, nearest first */
  entries(m: number, cardW: number): number[];
  /** spacing of n stacked horizontal runs in one band (3.5–6) */
  trackSpacing(n: number, room?: number): number;
  /** the break a crossing leaves in the horizontal ("h", 12 × 10) or vertical ("v", 10 × 12) line */
  bridge(x: number, y: number, broken?: "h" | "v"): Rect;
};
