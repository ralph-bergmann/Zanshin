import * as React from "react";

/** Nami — the Zanshin app mark: three gold waves on an indigo tile. */
export interface NamiMarkProps {
  /** px, default 28. ≤ 48px draws heavier waves (optical sizing). */
  size?: number;
  /** wrap in the hairline-ringed chip used in the top bar */
  chip?: boolean;
  /** waves only, no indigo tile */
  bare?: boolean;
  title?: string;
}
export declare function NamiMark(props: NamiMarkProps): JSX.Element;
