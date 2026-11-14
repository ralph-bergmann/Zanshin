import * as React from "react";
import type { MenuItem } from "../menus/Menu";

/** A Button that opens a Menu under itself (the inspector's Squash). States: the Button's — rest · hover · pressed · focus-visible · disabled (.4) · disabled with a reason (the reason on its wrapper) — plus open (the menu shows under it; the button keeps its rest look). */
export interface MenuButtonProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onSelect"> {
  /** the menu's rows; each row's `cmd` is its jj command, a disabled row's `title` its reason */
  items: Array<MenuItem | "sep">;
  onSelect?: (id: string | undefined, item: MenuItem) => void;
  /** as Button: default · primary · ghost · danger · destructive */
  variant?: "default" | "primary" | "ghost" | "danger" | "destructive";
  /** as Button */
  size?: "sm" | "md" | "lg";
  /** an Icon name or node before the label */
  icon?: string | React.ReactNode;
  /** with `title`: the reason, shown by the wrapper */
  disabled?: boolean;
  /** the tooltip (enabled) or the reason (disabled) */
  title?: string;
  /** the widest the menu grows; 360 fits commands with a change id (the DS menu's 320 does not) */
  menuMaxWidth?: number;
  /** the label, a verb in sentence case */
  children?: React.ReactNode;
}
export declare function MenuButton(props: MenuButtonProps): JSX.Element;
