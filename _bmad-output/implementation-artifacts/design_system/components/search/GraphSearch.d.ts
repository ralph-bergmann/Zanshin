import * as React from "react";

export type SearchScope = "any" | "change" | "bookmark" | "author" | "file" | "description";

/** Scope metadata: label, icon, prefix (c: b: a: f: d:), desc (menu column), placeholder / short placeholder, go (= selects a change), mono. */
export declare const SearchScopes: Record<SearchScope, { label: string; icon: string; go?: boolean; prefix?: string; desc?: string; placeholder: string; short?: string; mono?: boolean }>;

/** The `$` row glyph: mono 600 13px, --text-dim, moon when selected. */
export declare function SearchDollar(): JSX.Element;

/** The top bar's graph search field: [menu ▾ | query | ✕] — a 36px well inside the 44px View capsule. States: rest · hover · focus (accent edge + halo) · has a query or a variant (the pill untinted, as at the default; the variant name 500 in the field) · menu open · suggestions open · width steps · inactive window (at rest). */
export interface GraphSearchProps {
  /** scope of the typed text; Go to = change, bookmark; Filter by = author, file, description */
  scope?: SearchScope;
  /** the text in the field */
  value?: string;
  /** what the graph shows: the default search, a typed search, or another jj log variant (pill shows $, the field its name) */
  view?: "default" | "search" | "variant";
  /** name of the variant the graph shows (view "variant") */
  variantName?: string;
  /** built-in variants (jj log, all()) read in mono */
  variantMono?: boolean;
  /** name of the default search, for the tooltips */
  defaultName?: string;
  /** force the focused look (cards); otherwise follows real focus */
  focused?: boolean;
  menuOpen?: boolean;
  /** window-width step — use GraphSearch.sizeFor(innerWidth): full 320 · medium 250 · compact (pill icon only) · narrow 170, no ⌘F */
  size?: "full" | "medium" | "compact" | "narrow";
  placeholder?: string;
  /** ⌘F and / focus the field (default true) */
  hotkey?: boolean;
  /** id of the open list (aria-controls) */
  controls?: string;
  /** id of the keyboard row of the open list — focus stays in the field (aria-activedescendant) */
  activeDescendant?: string;
  /** suggestions are open (aria-expanded on the input) */
  expanded?: boolean;
  onChange?: (text: string, e: React.ChangeEvent<HTMLInputElement>) => void;
  /** typed prefixes and Backspace-in-an-empty-field change the scope through this */
  onScopeChange?: (scope: SearchScope) => void;
  /** the pill: opens the one menu */
  onMenu?: () => void;
  /** ✕: back to the default search */
  onClear?: () => void;
  onKeyDown?: React.KeyboardEventHandler<HTMLInputElement>;
  onFocus?: React.FocusEventHandler<HTMLInputElement>;
  onBlur?: React.FocusEventHandler<HTMLInputElement>;
  onMouseUp?: React.MouseEventHandler<HTMLInputElement>;
  inputRef?: React.RefObject<HTMLInputElement>;
  /** SearchMenu / SearchPopover — anchored 12px under the field */
  children?: React.ReactNode;
  className?: string;
  style?: React.CSSProperties;
}
export declare function GraphSearch(props: GraphSearchProps): JSX.Element;
export declare namespace GraphSearch { function sizeFor(windowWidth: number): "full" | "medium" | "compact" | "narrow"; }
