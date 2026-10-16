import * as React from "react";

/** Scroll container with the macOS overlay scrollbar (hidden at rest, widens near the edge, darkens while dragged). States: rest (bar hidden) · scrolling (shown) · pointer near the edge (track, wider thumb) · dragging · focus-visible (viewport ring inside). */
export interface ScrollAreaProps {
  /** "y" (default) or "both" — a second overlay bar along the bottom */
  axis?: "y" | "both";
  /** track click: true = one page toward the click (macOS default), false = jump to the spot; ⌥ inverts */
  pageJump?: boolean;
  /** VoiceOver name of the scroll region */
  label?: string;
  height?: number | string;
  children?: React.ReactNode;
  className?: string;
  style?: React.CSSProperties;
}
export declare function ScrollArea(props: ScrollAreaProps): JSX.Element;
