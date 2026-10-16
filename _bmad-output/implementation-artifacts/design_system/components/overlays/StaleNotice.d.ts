import * as React from "react";

/** "Working copy is stale" — a project-level notice over the graph (not a menu: jj refuses the workspace list too). States: notice only (sentence + command, Copy) · with the action (Update working copy, the command in its tooltip) · busy. */
export interface StaleNoticeProps {
  /** default "jj workspace update-stale" */
  command?: string;
  /** offers "Update working copy" — runs the command, then the result toast */
  onUpdate?: () => void;
  onCopy?: () => void;
  busy?: boolean;
  className?: string;
  style?: React.CSSProperties;
}
export declare function StaleNotice(props: StaleNoticeProps): JSX.Element;
