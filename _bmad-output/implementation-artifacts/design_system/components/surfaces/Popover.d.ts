import * as React from "react";

/** Settings sheet dropped from an island. States: open · closing; OptionLink: rest · hover · pressed · focus-visible (inside). */
export interface PopoverProps extends React.HTMLAttributes<HTMLDivElement> { width?: number; children?: React.ReactNode; }
export declare function Popover(props: PopoverProps): JSX.Element;
/** uppercase caps label (10.5px, +0.1em) */
export declare function PopoverHeader(props: { children?: React.ReactNode }): JSX.Element;
export declare function PopoverSeparator(): JSX.Element;
/** 36px row: label left, control right */
export interface OptionRowProps { label: React.ReactNode; title?: string; children?: React.ReactNode; }
export declare function OptionRow(props: OptionRowProps): JSX.Element;
/** 36px row that leads somewhere bigger (Settings… › General) — label left, action right; a shortcut only if the row does exactly what it does */
export interface OptionLinkProps { label: React.ReactNode; action?: React.ReactNode; shortcut?: string; onClick?: () => void; }
export declare function OptionLink(props: OptionLinkProps): JSX.Element;
