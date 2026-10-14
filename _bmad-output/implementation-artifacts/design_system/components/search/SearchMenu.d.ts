import * as React from "react";
import type { SearchScope } from "./GraphSearch";

export interface SearchMenuVariant {
  id: string;
  /** "jj log" / "all()" for built-ins, the configuration's name otherwise */
  name: string;
  builtin?: boolean;
  /** built-ins: one line of what they show */
  desc?: string;
  /** configurations: the revset expression (mono) */
  expr?: string;
  /** tooltip: the full command */
  cmd?: string;
}

/** The one search menu (420px, scrolls): default search · other jj log variants · Go to · Filter by · Edit Configurations…. */
export interface SearchMenuProps {
  /** menu order; the first is the default search (tag "Default"). Default: SearchMenu.builtins */
  variants?: SearchMenuVariant[];
  /** id of the variant the graph shows — selected row; null while a typed search is active */
  current?: string | null;
  /** scope of the active typed search — its row shows `value` instead of the description */
  scope?: SearchScope | null;
  value?: string;
  onPickVariant?: (id: string) => void;
  onPickScope?: (scope: SearchScope) => void;
  onEdit?: () => void;
  /** focus the selected row on mount (arrow keys move between rows) */
  autoFocus?: boolean;
  className?: string;
  style?: React.CSSProperties;
}
export declare function SearchMenu(props: SearchMenuProps): JSX.Element;
export declare namespace SearchMenu { const builtins: SearchMenuVariant[]; }
