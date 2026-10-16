import * as React from "react";

/** Tooltip: label (+ shortcut) over the jj command. --delay-tooltip (700ms) rest, at once while warm (--dur-tooltip-warm), fades out on --dur-exit; flips and clamps 8px inside the window. States: hidden · waiting (--delay-tooltip) · shown (flipped and clamped at the window edge) · warm (at once) · closing. */
export interface TooltipProps {
  label: React.ReactNode;
  /** the exact jj command, mono, second line */
  cmd?: string;
  /** plain-text shortcut, right of the label ("⌘N") */
  shortcut?: string;
  /** bottom (default, top-bar controls) · top · right (rail) · left */
  placement?: "bottom" | "top" | "right" | "left";
  /** force it open (specimens) */
  open?: boolean;
  delay?: number;
  children: React.ReactNode;
  className?: string;
}
export declare function Tooltip(props: TooltipProps): JSX.Element;
