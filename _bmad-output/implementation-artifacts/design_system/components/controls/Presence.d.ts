import * as React from "react";

/** Keeps a layer mounted while its exit plays: <Presence open={o}>{(closing) => <Menu closing={closing} … />}</Presence> States: mounted · closing (kept mounted for the exit) · gone. */
export interface PresenceProps {
  open: boolean;
  /** exit length in ms — 120 (menus, popovers, tooltips) · 180 (dialogs, toasts) */
  exit?: number;
  children: (closing: boolean) => React.ReactNode;
}
export declare function Presence(props: PresenceProps): JSX.Element;
