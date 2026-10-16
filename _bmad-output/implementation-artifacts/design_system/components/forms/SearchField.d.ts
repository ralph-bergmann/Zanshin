import * as React from "react";

/** List search field (Projects, bookmarks): 30px (--control-md) quiet fill — a named exception to the text-entry well, moon focus border + halo, clear ✕ with a query. States: rest (quiet fill) · hover · focus (accent edge + halo) · with a query (✕) · disabled · inactive window (at rest). */
export interface SearchFieldProps {
  value?: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  autoFocus?: boolean;
  label?: string;
  style?: React.CSSProperties;
  /** key cap shown while empty and unfocused, e.g. "/" */
  shortcut?: string;
  onClear?: () => void;
  className?: string;
}
export declare function SearchField(props: SearchFieldProps): JSX.Element;
