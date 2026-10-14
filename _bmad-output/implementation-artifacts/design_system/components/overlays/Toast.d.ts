import * as React from "react";

/** Undo toast after a graph edit: "Moved ovknl onto vruxw · Undo · ×". */
export interface ToastProps {
  /** sentence with ChangeIds / <code> inline */
  children?: React.ReactNode;
  /** shows the Undo button (title "jj undo") */
  onUndo?: () => void;
  /** shows the dismiss × */
  onClose?: () => void;
  undoLabel?: string;
  className?: string;
  style?: React.CSSProperties;
}
export declare function Toast(props: ToastProps): JSX.Element;
