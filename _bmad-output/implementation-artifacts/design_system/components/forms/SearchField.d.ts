import * as React from "react";

/** 32px search input. */
export interface SearchFieldProps { value?: string; onChange?: (v: string) => void; placeholder?: string; autoFocus?: boolean; label?: string; style?: React.CSSProperties; }
export declare function SearchField(props: SearchFieldProps): JSX.Element;
