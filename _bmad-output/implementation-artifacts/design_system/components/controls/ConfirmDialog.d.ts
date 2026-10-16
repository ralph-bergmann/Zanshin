import * as React from "react";

/** Confirmation / warning dialog for actions jj undo can't reverse. 420px glass sheet, title 15/600, body, optional command well. States: open · busy · closing · tone destructive / warn / default. */
export interface ConfirmDialogProps {
  title: string;
  children?: React.ReactNode;
  /** the exact command(s) it will run, in a mono well */
  cmd?: string;
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
export declare function ConfirmDialog(props: ConfirmDialogProps): JSX.Element;
