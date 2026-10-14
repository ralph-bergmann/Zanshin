import * as React from "react";

/** Inset text field (input or textarea) for settings and describing a change. */
export interface TextFieldProps extends React.InputHTMLAttributes<HTMLInputElement & HTMLTextAreaElement> {
  /** sm 30px (settings) · md 34px semibold (composer summary) · lg 36px 15px semibold (describe summary) */
  size?: "sm" | "md" | "lg";
  /** textarea for the details; with size "md" it is the compact composer version */
  multiline?: boolean;
  /** JetBrains Mono — for revsets and config values */
  mono?: boolean;
  rows?: number;
  inputRef?: React.Ref<any>;
}
export declare function TextField(props: TextFieldProps): JSX.Element;
