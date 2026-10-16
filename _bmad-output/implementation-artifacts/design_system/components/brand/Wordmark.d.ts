import * as React from "react";

/** ZANSHIN wordmark — monoline stroke paths, gold gradient / ink / white. States: none — a static mark. */
export interface WordmarkProps {
  /** cap height in px, default 38 (splash). Stroke scales with it. */
  height?: number;
  /** gold on night (default) · ink (#26304d) on paper · white on pure black */
  variant?: "gold" | "ink" | "white";
  title?: string;
}
export declare function Wordmark(props: WordmarkProps): JSX.Element;
