import * as React from "react";

/** "@ Working copy" locator pill. */
export interface AtPillProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** where @ is relative to the viewport */
  direction?: "down" | "up" | "left" | "right";
  label?: string;
}
export declare function AtPill(props: AtPillProps): JSX.Element;
