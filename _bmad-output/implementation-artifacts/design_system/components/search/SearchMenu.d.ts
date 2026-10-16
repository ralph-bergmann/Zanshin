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

/** The one search menu (420px, scrolls): default search · other jj log variants · Go to · Filter by · Edit Configurations…. A field-attached list. States: rest · hover (--fl-hover) · pressed (--fl-on) · keyboard row (--accent-soft) · current (a check) · closing. */
export interface SearchMenuProps {
  /** menu order; the first is the default search (tag "Default"). Default: SearchMenu.builtins */
  variants?: SearchMenuVariant[];
  /** id of the variant the graph shows — its row carries a check (never the fill); null while a typed search is active */
  current?: string | null;
  /** scope of the active typed search — its row shows `value` instead of the description */
  scope?: SearchScope | null;
  value?: string;
  onPickVariant?: (id: string) => void;
  onPickScope?: (scope: SearchScope) => void;
  onEdit?: () => void;
  /** index of the keyboard row (the field keeps focus; use SearchMenu.navigate in its onKeyDown and name the row with aria-activedescendant: listId-<index>) */
  active?: number;
  listId?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function SearchMenu(props: SearchMenuProps): JSX.Element;
export declare namespace SearchMenu {
  const builtins: SearchMenuVariant[];
  /** number of rows: the variants, five scopes, Edit Configurations… */
  function count(variants?: SearchMenuVariant[]): number;
  /** ↑ ↓ (wrap) Home End → the new keyboard row, or null for any other key */
  function navigate(e: { key: string }, active: number, count: number): number | null;
}
