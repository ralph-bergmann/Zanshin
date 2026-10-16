import * as React from "react";

/** Disclosure row: chevron + label (+ meta), the body opens with a height animation. States: closed · open (chevron 90°, height on --dur-expand) · hover · pressed · focus-visible (inside). */
export interface DisclosureProps {
  label: React.ReactNode;
  open?: boolean;
  defaultOpen?: boolean;
  onToggle?: (open: boolean) => void;
  /** right side, mono: a count */
  meta?: React.ReactNode;
  children?: React.ReactNode;
  className?: string;
}
export declare function Disclosure(props: DisclosureProps): JSX.Element;
