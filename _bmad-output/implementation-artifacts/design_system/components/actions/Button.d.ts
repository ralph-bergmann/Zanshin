import * as React from "react";

/** Text button. One primary (gold) per view; everything else quiet. */
export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** default (quiet fill) · primary (gold — the ONE main action) · ghost · danger (quiet until hover) */
  variant?: "default" | "primary" | "ghost" | "danger";
  /** sm 30px (inspector) · md 32px (dialogs) · lg 44px (top-bar primary, glass) */
  size?: "sm" | "md" | "lg";
  /** icon name or node, sits before the label */
  icon?: string | React.ReactNode;
  iconSize?: number;
  children?: React.ReactNode;
}
export declare function Button(props: ButtonProps): JSX.Element;
