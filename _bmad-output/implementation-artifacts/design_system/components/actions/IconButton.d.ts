import * as React from "react";

/** Square icon button. sm 30 (--control-md) · md 36 (--control-lg, in islands) · lg 40 (rail); icons sm 12 · bar 17 · rail 19. Hover --fl-hover, pressed / on --fl-on, on + hover --fl-on-hover. States: rest · hover --fl-hover · pressed --fl-on · focus-visible ring (rail: inside) · on --fl-on → on + hover --fl-on-hover → on + pressed --fl-press · disabled .4 (with a reason: aria-disabled) · badge. */
export interface IconButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  icon: string | React.ReactNode;
  /** accessible name; also the default tooltip */
  label: string;
  size?: "sm" | "md" | "lg";
  /** toggled on / its panel is open (aria-pressed) */
  active?: boolean;
  /** a count on the top-right corner; 0 hides it (with its exit) */
  badge?: number | string;
  /** an --icon-* name or px; default sm / bar / rail by size */
  iconSize?: "xs" | "sm" | "md" | "lg" | "bar" | "rail" | number;
}
export declare function IconButton(props: IconButtonProps): JSX.Element;
