import * as React from "react";

/** Zanshin UI icon (16px grid, 1.3–1.6 stroke, round caps, currentColor). Icon.names lists every glyph. */
export interface IconProps extends React.SVGProps<SVGSVGElement> {
  /** kebab-case glyph name: plus, branch, workstream, reviews, undo, fetch, push, edit, describe, squash, abandon, conflict, merge, bookmark, bookmark-filled, chevron-down, close, search, folder, … */
  name: string;
  /** px, default 16 */
  size?: number;
  /** accessible label; omit for decorative icons */
  title?: string;
}
export declare function Icon(props: IconProps): JSX.Element | null;
export declare namespace Icon { const names: string[]; }
