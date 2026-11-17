import * as React from "react";
import type { MenuItem } from "../menus/Menu";

/** One shape, two parts (Story 10.48): the label runs its command, the divided chevron opens the alternatives in a Menu 4px below the button's left edge. Each part is its own button. States per part: rest · hover · pressed · focus-visible (the ring inside) · disabled (.4) · disabled with a reason (its title); the shape keeps the variant's rest fill and ring. */
export interface SplitButtonProps {
  /** the command the label runs, a verb in sentence case — it always names what a click runs */
  label: string;
  /** the alternatives; each row's `cmd` is its jj command, a row's `note` what it does beyond the label (where the bookmarks land), `onHighlight` lets a preview follow it */
  items: Array<MenuItem | "sep">;
  /** the label's click, Space or ↩ */
  onRun?: () => void;
  onSelect?: (id: string | undefined, item: MenuItem) => void;
  /** default (the quiet fill) or primary (the gold of the one primary action); no other variant exists */
  variant?: "default" | "primary";
  /** md 30 (padding 0 12, the chevron 0 7, --radius-btn, --type-control) · sm 26 (0 10 / 0 6, radius 8, 12px) */
  size?: "md" | "sm";
  /** the label disabled; the chevron keeps working */
  disabled?: boolean;
  /** the label's tooltip: its command, or the reason it is off */
  title?: string;
  /** the chevron disabled (busy, or every alternative off) */
  menuDisabled?: boolean;
  /** the chevron's reason */
  menuTitle?: string;
  /** the widest the menu grows (360) */
  menuMaxWidth?: number;
  /** forces a state on the label for specimens: st-hover · st-press · st-focus */
  mainClassName?: string;
  /** forces a state on the chevron for specimens */
  chevClassName?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function SplitButton(props: SplitButtonProps): JSX.Element;
