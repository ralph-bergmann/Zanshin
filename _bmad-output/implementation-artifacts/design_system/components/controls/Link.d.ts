import * as React from "react";

/** Link: inline (accent text, underline on hover) or quiet (dim → text). Focus = the 2px ring. States: rest · hover (inline: underline · quiet: --text) · pressed (--text) · focus-visible (ring, radius 3). */
export interface LinkProps extends React.AnchorHTMLAttributes<HTMLAnchorElement> {
  href?: string;
  quiet?: boolean;
  /** opens outside Zanshin — adds ↗ */
  external?: boolean;
  children?: React.ReactNode;
}
export declare function Link(props: LinkProps): JSX.Element;
