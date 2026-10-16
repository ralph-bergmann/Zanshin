import * as React from "react";

/** Floating glass container — every control above the graph lives in one. States: none of its own — glass at rest; solid under Reduce transparency. */
export interface IslandProps extends React.HTMLAttributes<HTMLElement> {
  /** bar (44px top bar) · rail (vertical icon column) · panel (inspector, stronger glass) · free */
  shape?: "bar" | "rail" | "panel" | "free";
  /** element to render, default "div" (e.g. "button", "nav") */
  as?: any;
  children?: React.ReactNode;
}
export declare function Island(props: IslandProps): JSX.Element;
/** 1 × 20px hairline between groups inside a bar island */
export declare function IslandSeparator(): JSX.Element;
