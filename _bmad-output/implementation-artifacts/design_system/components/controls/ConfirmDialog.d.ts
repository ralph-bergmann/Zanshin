import * as React from "react";

/** Confirmation / warning dialog for actions jj undo can't reverse. 420px glass sheet, title 15/600, body, optional command well or choice list. States: open · busy · closing · tone destructive / warn / default. */
export interface ConfirmDialogProps {
  title: string;
  children?: React.ReactNode;
  /** the exact command(s) it will run, in a mono well; not shown with `choices` */
  cmd?: string;
  /** one decision whose choices run different commands: a radio group of rows, each label (+ "default"), its commands and a note */
  choices?: ConfirmDialogChoice[];
  /** the chosen choice's id (controlled) */
  value?: string;
  /** the choice chosen at open, marked "default" */
  defaultValue?: string;
  onChoose?: (id: string) => void;
  /** the radio group's accessible name */
  choicesLabel?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  /** destructive (filled red, ⌘↩, focus on Cancel) · warn (amber mark, gold primary) · default (gold primary) */
  tone?: "destructive" | "warn" | "default";
  onConfirm?: () => void;
  onCancel?: () => void;
  /** spinner in the confirm button while it runs */
  busy?: boolean;
  /** play the exit */
  closing?: boolean;
  scrim?: boolean;
  width?: number;
}
/** One choice of a ConfirmDialog: what it does, the exact commands it runs in order, a note on undo; danger in --rem. */
export interface ConfirmDialogChoice {
  id: string;
  label: string;
  cmd: string[];
  note?: string;
  danger?: boolean;
}
export declare function ConfirmDialog(props: ConfirmDialogProps): JSX.Element;
