import * as React from "react";

/** Text button. One primary (gold) per view; everything else quiet. States: rest · hover · pressed (one fill step, instant) · focus-visible · disabled (.4) · disabled with a reason (aria-disabled: no hover, no press, the reason on its wrapper) · busy (spinner, aria-busy, cursor progress) · inactive window (the gold stays). */
export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** default (quiet fill) · primary (gold — the ONE main action) · ghost · danger (quiet until hover, red tint) · destructive (filled red — the one primary of a confirmation) */
  variant?: "default" | "primary" | "ghost" | "danger" | "destructive";
  /** sm = md = 30px (--control-md — one height for inspector, dialogs, settings; md kept for existing calls) · lg 44px (--control-xl, top-bar primary, glass) */
  size?: "sm" | "md" | "lg";
  /** icon name or node, sits before the label; without children the button is icon-only (square) */
  icon?: string | React.ReactNode;
  /** an --icon-* name or px; default md (lg on lg) */
  iconSize?: "xs" | "sm" | "md" | "lg" | "bar" | "rail" | number;
  /** spinner in the icon slot, label stays, aria-busy, clicks ignored */
  busy?: boolean;
  /** accessible name for icon-only buttons (also the tooltip) */
  label?: string;
  children?: React.ReactNode;
}
export declare function Button(props: ButtonProps): JSX.Element;
