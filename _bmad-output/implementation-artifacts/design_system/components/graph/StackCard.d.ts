import * as React from "react";

/** A folded linear run of changes. */
export interface StackCardProps extends React.HTMLAttributes<HTMLDivElement> { count: number; subject: string; from: string; to: string; author?: string; date?: string; detailed?: boolean; width?: number; }
export declare function StackCard(props: StackCardProps): JSX.Element;
