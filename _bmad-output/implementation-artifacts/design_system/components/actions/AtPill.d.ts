import * as React from "react";

/** "@ Working copy" locator pill. States: hidden · in (fade + rise) · hover --fl-hover · pressed --fl-on · focus-visible ring · direction up / down / left / right (the arrow turns). */
export interface AtPillProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** where @ is relative to the viewport */
  direction?: "down" | "up" | "left" | "right";
  label?: string;
}
export declare function AtPill(props: AtPillProps): JSX.Element;
