import * as React from "react";

/** Square icon-only button. */
export interface IconButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  icon: string | React.ReactNode;
  /** accessible name (also the default tooltip) */
  label: string;
  /** sm 28 (panel close) · md 36 (inside islands) · lg 40 (rail) */
  size?: "sm" | "md" | "lg";
  /** pressed / open state */
  active?: boolean;
  iconSize?: number;
}
export declare function IconButton(props: IconButtonProps): JSX.Element;
