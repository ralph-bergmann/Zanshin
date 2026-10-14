import * as React from "react";

/** Context menu for a change. */
export interface MenuItem { id: string; label: string; icon?: string; cmd?: string; danger?: boolean; disabled?: boolean; }
export interface MenuProps extends React.HTMLAttributes<HTMLDivElement> {
  /** change id shown in the head */
  id?: string;
  subject?: string;
  workingCopy?: boolean;
  /** items; "sep" draws a separator */
  items: Array<MenuItem | "sep">;
  onSelect?: (id: string) => void;
}
export declare function Menu(props: MenuProps): JSX.Element;
