import * as React from "react";

/** Hover preview attached to a rail button. States: in (after --delay-callout) · closing. */
export interface CalloutProps { icon?: string; title?: string; count?: number | string; arrow?: boolean; className?: string; style?: React.CSSProperties; children?: React.ReactNode; }
export declare function Callout(props: CalloutProps): JSX.Element;
export declare function CalloutText(props: { children?: React.ReactNode }): JSX.Element;
