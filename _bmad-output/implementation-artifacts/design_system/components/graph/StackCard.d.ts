import * as React from "react";

/** A folded linear run of changes. States: rest · hover (both edges brighten) · selected · @ · focus-visible — as ChangeCard · immutable (every member is: the front card hatched). */
export interface StackCardProps extends React.HTMLAttributes<HTMLDivElement> { count: number; subject: string; from: string; to: string; author?: string; date?: string; detailed?: boolean; immutable?: boolean; width?: number; }
export declare function StackCard(props: StackCardProps): JSX.Element;
