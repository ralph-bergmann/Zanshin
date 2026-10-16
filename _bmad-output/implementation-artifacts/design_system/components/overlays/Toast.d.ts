import * as React from "react";

/** The undo toast (and its refusal / failure variants): a 36px glass pill (--control-lg), bottom centre; Undo / Redo / Retry 26px. States: in · success / warn / error · hover (timer paused) · replaced · closing. */
export interface ToastProps {
  children?: React.ReactNode;
  /** success (default) · warn (refused — nothing changed) · error (failed — offer Retry, no auto-hide) */
  tone?: "success" | "warn" | "error";
  onUndo?: () => void;
  undoLabel?: string;
  /** a second quiet pill, e.g. { label: "Retry", onClick, title: "jj git fetch" } */
  action?: { label: string; onClick?: () => void; title?: string };
  onClose?: () => void;
  /** play the exit: slide 8px down + fade, --dur-exit-lg */
  closing?: boolean;
  /** replaced by a newer toast: fade in place, --dur-exit */
  replaced?: boolean;
  className?: string;
  style?: React.CSSProperties;
}
export declare function Toast(props: ToastProps): JSX.Element;
