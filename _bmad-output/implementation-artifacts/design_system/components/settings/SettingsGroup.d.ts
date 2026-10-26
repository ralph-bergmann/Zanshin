import * as React from "react";

/**
 * Caps heading + one rounded box of SettingsRows.
 * States: none — a container.
 */
export interface SettingsGroupProps {
  /** caps heading, e.g. "Appearance", "Remotes" */
  title?: string;
  /** mono, faint, not in caps — beside the heading: the revset or key the group stands for (e.g. "builtin_immutable_heads()") */
  meta?: string;
  /** no box around the children (a result well, a note line) */
  bare?: boolean;
  className?: string;
  children?: React.ReactNode;
}
export declare function SettingsGroup(props: SettingsGroupProps): JSX.Element;
