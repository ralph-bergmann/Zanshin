import * as React from "react";

/** Status pill. States: neutral · wc (@) · warn — static. */
export interface FlagProps {
  kind?: "neutral" | "wc" | "warn";
  /** an Icon name, or a node — Immutable carries <HatchSwatch/> */
  icon?: string | React.ReactNode;
  /** the reason, e.g. "Immutable · below trunk() · main" */
  title?: string;
  children?: React.ReactNode;
}
export declare function Flag(props: FlagProps): JSX.Element;
