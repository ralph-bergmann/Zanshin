import * as React from "react";

/** The band between two panes of a split — the inspector's divider between its file list and its diff. States: rest (the 4px grip in --fl-border, 10 % of the length) · hover and dragging (a full-length 2px --accent line) · focus-visible (the ring inside) · double-click → default. */
export interface SplitDividerProps {
  /** "x": the panes side by side (vertical band, col-resize) · "y": stacked (horizontal band, row-resize) */
  axis?: "x" | "y";
  /** the leading pane's length in px */
  value: number;
  /** the leading pane's minimum (files: 220 side by side, 110 stacked) */
  min?: number;
  /** what leaves the other pane its minimum (diff: 320 / 140); wins over min when both cannot fit */
  max?: number;
  /** double-click and ↩ */
  defaultValue?: number;
  /** what both panes share (the band left out): the value VoiceOver reads is value / total in percent */
  total?: number;
  /** "Files and diff" */
  label?: string;
  /** live while dragging and on every key */
  onChange?: (value: number) => void;
  /** once when a drag ends, on each key and on reset — remember the share here, never per move */
  onChangeEnd?: (value: number) => void;
  className?: string;
  style?: React.CSSProperties;
}
export declare function SplitDivider(props: SplitDividerProps): JSX.Element;
