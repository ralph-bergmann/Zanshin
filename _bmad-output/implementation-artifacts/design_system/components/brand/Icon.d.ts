import * as React from "react";

/** Zanshin UI icon — 59 glyphs drawn on 16 (one 1.5 stroke, round caps and joins, currentColor; retired names resolve through aliases). Icon.names lists every glyph. States: none of its own — it takes the colour of the control it sits in (currentColor). */
export interface IconProps extends React.SVGProps<SVGSVGElement> {
  /** kebab-case glyph name: plus, branch, reviews, undo, fetch, push, describe, working-copy-at, squash, abandon, conflict, merge, bookmark, bookmark-filled, chevron-down, close, search, folder, … */
  name: string;
  /** a token — xs 10 · sm 12 · md 14 · lg 16 (default) · bar 17 · rail 19 (the --icon-* tokens) — or px */
  size?: IconSize | number;
  /** accessible label; omit for decorative icons */
  title?: string;
}
export type IconSize = "xs" | "sm" | "md" | "lg" | "bar" | "rail";
export declare function Icon(props: IconProps): JSX.Element | null;
export declare namespace Icon { const names: string[]; const sizes: Record<IconSize, number>; }
