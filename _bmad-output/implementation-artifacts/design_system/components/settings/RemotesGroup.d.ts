import * as React from "react";

export interface Remote {
  name: string;
  /** the fetch URL, verbatim (credentials included — the component hides them); null for a push-only remote ("No fetch URL") */
  url: string | null;
  /** only when it differs from url (jj git remote list's "(push: …)") */
  pushUrl?: string | null;
}
/** One jj verb, as the row's form (or Remove…) asks for it. set-url carries only the sides that change. */
export type RemoteOp =
  | { verb: "add"; name: string; url: string; pushUrl: string | null }
  | { verb: "rename"; name: string; newName: string }
  | { verb: "set-url"; name: string; url: string | null; pushUrl: string | null }
  | { verb: "remove"; name: string };
export interface RemoteRefusal {
  /** jj's message, verbatim ("Git remote named 'origin' already exists") */
  message: string;
  /** one plain sentence where jj's words need one (nonstandard configuration, the reserved name git) */
  help?: React.ReactNode;
}
export interface RemoteFormState {
  mode: "add" | "rename" | "url";
  /** the remote being renamed or re-pointed (null for add) */
  of: string | null;
  name: string;
  url: string;
  push: string;
  refusal?: RemoteRefusal | null;
}
/** Settings › Project › Remotes — a SettingsGroup. States: list (fetch URL, push URL when it differs, credentials hidden) · empty · the ••• menu · a row as a form (Add · Rename · Set URL: fields, the command, Cancel + the verb) · a refusal under the form or the row (jj verbatim + help) · a warning under a new row ("Remote origin already uses the same URL.") · Remove asking (ConfirmDialog). */
export interface RemotesGroupProps {
  remotes: Remote[];
  /** runs the verb (the bridge: gitRemoteAdd / Rename / SetUrl / Remove) and reports back; the app then reads the remotes again */
  onRun?: (op: RemoteOp) => null | { refusal?: RemoteRefusal; warning?: { message: string; hint?: string } };
  /** cards: start with a form open */
  initialForm?: RemoteFormState | null;
  /** cards: start with a refusal or warning under a row */
  initialNotes?: Record<string, { refusal?: RemoteRefusal; warning?: { message: string; hint?: string } }>;
  /** the group's other rows, after the list: Fetch from · Push to · Fetch automatically */
  children?: React.ReactNode;
  className?: string;
}
export declare function RemotesGroup(props: RemotesGroupProps): JSX.Element;
export declare namespace RemotesGroup {
  /** hides everything between "scheme://" and "@": https://•••@git.example.com/team/myapp.git */
  function scrub(url: string | null): string | null;
  /** the exact command, shell-quoted, credentials hidden: jj git remote set-url origin --push git@github.com:ralph/jj.git */
  function command(op: RemoteOp): string;
}
