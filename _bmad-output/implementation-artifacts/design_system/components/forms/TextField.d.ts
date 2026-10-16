import * as React from "react";

/** Inset text field: sm 30 (settings) · md 36 / 13 semibold (composer) · lg 36 / 15 semibold (describe) — --control-md / --control-lg. Text entry shows focus as moon border + 3px halo. States: rest · hover · focus (any: accent edge + halo) · error · error + focus · read-only · disabled · inactive window (at rest, no caret). */
export interface TextFieldProps extends React.InputHTMLAttributes<HTMLInputElement> {
  size?: "sm" | "md" | "lg";
  /** textarea instead of input */
  multiline?: boolean;
  /** JetBrains Mono 12 — revsets, config values */
  mono?: boolean;
  rows?: number;
  inputRef?: React.Ref<any>;
  /** invalid: true, or the message to show under the field (red) */
  error?: boolean | string;
  /** a neutral hint line under the field */
  message?: string;
  readOnly?: boolean;
}
export declare function TextField(props: TextFieldProps): JSX.Element;
