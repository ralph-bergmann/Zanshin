import * as React from "react";

/** jj change id with bold unique prefix. States: none — immutable adds ◆. */
export interface ChangeIdProps {
  id: string;
  /** characters shown, default 5 (8 in detailed cards, menus, toasts, search rows) */
  length?: number;
  /** characters set bold, default 2; a search row bolds what was typed (e.g. 4 for "plkm") */
  prefix?: number;
  immutable?: boolean;
}
export declare function ChangeId(props: ChangeIdProps): JSX.Element;
