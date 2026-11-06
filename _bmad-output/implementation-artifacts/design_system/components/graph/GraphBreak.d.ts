import * as React from "react";

/** A shortened card-free stretch of the Free layout (Story 10.31): a torn strip across the plane over the lines, its span at the left edge (sticky). Place it after the lines and before the cards. States: none. */
export interface GraphBreakProps {
  /** the band: the upper card's bottom … the lower card's top, in plane px (1½ pitches card to card, minus the card) */
  top: number;
  bottom: number;
  /** the plane's width — the strip runs across all of it */
  width: number;
  /** the span it skips — GraphBreak.label(t0, t1): "4 years · Feb 2021 – Mar 2025" */
  label?: string;
  /** like DayAxis: sticky offset of the label column (floating client: inset − 6) and the inset inside it (14, 2 in the floating client) */
  stickyLeft?: number;
  labelLeft?: number;
  className?: string;
  style?: React.CSSProperties;
}
export declare function GraphBreak(props: GraphBreakProps): JSX.Element;
export declare namespace GraphBreak {
  /** the label for a break from the lower card's time t0 to the upper card's t1 (ms): length · range */
  function label(t0: number, t1: number): string;
}
