import * as React from "react";

/** The grab zone on an island's edge toward the graph — inspector (side "left") and pinned panels (side "right"). A sibling of the island in the same positioned container. States: rest (invisible) · hover (resize cursor at once, the 2px line after --delay-resize) · dragging (line stays, live) · at min / at max (one-way cursor) · focus-visible · double-click → default. */
export interface ResizeEdgeProps {
  /** "left": the edge is the island's left (the inspector) · "right": its right (a pinned panel) */
  side?: "left" | "right";
  /** the edge's distance in px from the side the island hangs from: inspector 12 + width (from the right) · panel 76 + width (from the left) */
  at?: number;
  /** the island's top / bottom offsets — the zone leaves its --radius-panel corners out */
  top?: number;
  bottom?: number;
  /** the current width (px = pt) */
  value: number;
  /** --inspector-w-min / --panel-w-min … --inspector-w-max / --panel-w-max */
  min: number;
  max: number;
  /** --inspector-w (460) / --panel-w (300): double-click and ↩ */
  defaultValue?: number;
  /** what the window allows right now — keeps --graph-min-w (320) of graph visible; a drag stops there */
  limit?: number;
  /** arrow-key step (⇧ × 5); default 10 */
  step?: number;
  /** "Inspector width" · "Panel width" (VoiceOver: "Inspector width, 460 points, splitter") */
  label?: string;
  /** live while dragging and on every key; remember the value app-wide */
  onChange?: (width: number) => void;
  /** double-click / ↩ (default: onChange(defaultValue)) */
  onReset?: () => void;
  className?: string;
  style?: React.CSSProperties;
}
export declare function ResizeEdge(props: ResizeEdgeProps): JSX.Element;
