import * as React from "react";

export interface DropAction {
  id: string;
  label: string;
  /** glyph: move-onto · move-only · insert-after · insert-before · squash-into · merge-new · duplicate · bookmark */
  icon?: string;
  /** short jj verb shown right, mono: "rebase -s", "squash", "split -A" */
  hint?: string;
  /** shown instead of the hint, in warn colour (e.g. "backwards") */
  note?: string;
  /** full command for the footer: "jj rebase -s ovknlmro -o vruxwmqv" */
  cmd?: string;
  /** items of different groups get a hairline between them: move · place · combine · copy */
  group?: string;
}
/** Menu over a drop target while dragging a change, bookmark, file or hunk. */
export interface DropMenuProps {
  items: DropAction[];
  /** index of the highlighted (default) action */
  active?: number;
  /** "above" the card: list runs bottom-up, command at the bottom */
  place?: "above" | "below";
  onSelect?: (id: string, index: number) => void;
  onActive?: (index: number) => void;
  className?: string;
  style?: React.CSSProperties;
}
export declare function DropMenu(props: DropMenuProps): JSX.Element;
