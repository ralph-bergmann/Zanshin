import * as React from "react";

export interface MenuItem {
  id?: string;
  label?: React.ReactNode;
  /** what typeahead matches when the label is a node */
  text?: string;
  /** an Icon name or a node */
  icon?: string | React.ReactNode;
  /** the jj command, right column, mono */
  cmd?: string;
  /** a keyboard shortcut, right column, plain text ("⌘C") */
  shortcut?: string;
  danger?: boolean;
  disabled?: boolean;
  /** makes it a check item (the check replaces the icon column) */
  checked?: boolean;
  /** with checked: one-of-many (menuitemradio) */
  radio?: boolean;
  /** nested items — the row shows › and opens them to the right */
  submenu?: Array<MenuItem | "sep">;
  /** a section heading (caps), not actionable */
  header?: string;
  /** a note row, not actionable — why something is missing ("Immutable · below trunk() · main"); 11.5px --text-dim, wraps; `icon` sits in the leading column (e.g. <HatchSwatch/>). The keyboard skips it; the menu is described by it. */
  note?: React.ReactNode;
  /** with disabled: the reason — shown by the row's wrapper, which still takes hover */
  title?: string;
}
/** Command menu. Solid accent highlight with ink text; danger rows a red tint. Blink on activation, then onSelect. States: rest · highlighted row (solid accent) · danger highlight (red tint) · disabled row (its reason on the wrapper) · note row · check · submenu open (flips at the edge) · blink · closing. */
export interface MenuProps extends Omit<React.HTMLAttributes<HTMLDivElement>, "onSelect"> {
  /** change id shown in the head */
  id?: string;
  subject?: string;
  workingCopy?: boolean;
  items: Array<MenuItem | "sep">;
  onSelect?: (id: string | undefined, item: MenuItem) => void;
  /** ← / Esc */
  onClose?: () => void;
  /** take keyboard focus on mount (context menus, SelectMenu) */
  autoFocus?: boolean;
  /** activation blink before onSelect (default true) */
  blink?: boolean;
  /** start with this row highlighted (index into items) */
  highlight?: number;
  /** play the exit (keep mounted for --dur-exit, e.g. with Presence) */
  closing?: boolean;
  /** no entrance animation (specimens) */
  still?: boolean;
}
export declare function Menu(props: MenuProps): JSX.Element;
