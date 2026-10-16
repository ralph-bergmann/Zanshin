import * as React from "react";

/** Status pill. States: neutral · wc (@) · warn — static. */
export interface FlagProps { kind?: "neutral" | "wc" | "warn"; icon?: string; title?: string; children?: React.ReactNode; }
export declare function Flag(props: FlagProps): JSX.Element;
