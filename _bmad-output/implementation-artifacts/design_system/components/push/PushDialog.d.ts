import * as React from "react";

/** jj's commit checks — three can be allowed by a flag (--allow-empty-description / --allow-private / --allow-conflicts), "no-author" can't. */
export type PushCommitRefusal = "empty-description" | "private" | "conflicts" | "no-author";
/** refusals of one remote, none allowable: the bookmark is conflicted there (hint jj git fetch), an untracked <name>@<remote> exists
 * (hint jj bookmark track <name>@<remote>), or it is tracked on another remote ("Refusing to create new remote bookmark"). */
export type PushRemoteRefusal = "conflicted" | "untracked-remote" | "tracked-elsewhere";

/** What a ref does on one remote — the --dry-run result there. */
export interface PushTarget {
  /** tracked on this remote; a ref tracked nowhere is tracked by the push */
  tracked?: boolean;
  /** change the remote has now (null: not there) → the change it will have (null: deleted) */
  from?: string | null;
  to?: string | null;
  /** new · forward · backward / sideways (rewrite history) · delete · none (up to date) */
  kind: "new" | "forward" | "backward" | "sideways" | "delete" | "none";
  /** part of what `jj git push` alone sends to this remote: a tracked bookmark in remote_bookmarks(remote=<remote>)..@, a tracked tag */
  inDefault?: boolean;
  /** only inside `remotes`: why this remote refuses it */
  refused?: PushRemoteRefusal | PushRemoteRefusal[];
}

/** A bookmark or tag the push could send. The top-level PushTarget fields are its result on every chosen remote (one remote, or the
 * same everywhere); `remotes` gives one per remote when they differ (forward on origin, new on upstream). */
export interface PushBookmark extends Omit<PushTarget, "refused"> {
  name: string;
  /** a tag: marked TAG, sent by hand with --tag <name>; the default and every bulk choice include tags too */
  type?: "bookmark" | "tag";
  remotes?: Record<string, PushTarget>;
  /** jj refuses the commit(s) it would send — on every remote; several reasons at once ("has no description and has conflicts");
   * "conflicted" here = the local bookmark is conflicted (hint jj git fetch) */
  refused?: PushCommitRefusal | "conflicted" | (PushCommitRefusal | "conflicted")[];
  /** the offending change (defaults to `to`) */
  refusedAt?: string;
}

/** One ref on one remote after a push that failed in part — jj checks the lease ref by ref, pushes the rest and records the operation. */
export interface PushResult {
  /** the bookmark's name; a tag as "tag:<name>" */
  ref: string;
  remote: string;
  /** pushed · lease (the remote moved the ref since the last fetch) · rejected (by the remote: permissions, hooks) */
  status: "pushed" | "lease" | "rejected";
  /** the remote's own message for a rejection */
  message?: string;
}

/** Push sheet — a surface for exactly the parameters of jj git push (v0.46.0). States: ready (the default selection) · hand-picked · bulk (tracked / all / deleted) · with tags · several remotes (one line per remote) · with a change (--change / --named) · warnings (backwards, sideways, delete) · refused — allowable (Allow chip, also on the change) or not (jj's hint), several reasons · nothing to push · pushing (progress, busy primary) · error (network, auth) · done (some refs pushed, some not: lease, rejected) · closing. The scrim takes no clicks. */
export interface PushDialogProps {
  remotes?: string[];
  /** the remotes `jj git push` uses without --remote: git.push (a name, a list or a pattern, resolved), else the only remote, else origin */
  defaultRemotes?: string[];
  /** shorthand for one default remote */
  defaultRemote?: string;
  /** chosen remotes (default: defaultRemotes); any other choice lists every one as --remote <name> */
  remote?: string[];
  onRemote?: (remotes: string[]) => void;
  bookmarks?: PushBookmark[];
  /** keys ticked (bookmark name, "tag:<name>"); default: the refs with inDefault on a chosen remote */
  selected?: string[];
  onSelect?: (keys: string[]) => void;
  /** the bulk choice the selection came from → --tracked / --all / --deleted; null = by hand (each --bookmark / --tag) */
  bulk?: "tracked" | "all" | "deleted" | null;
  onBulk?: (bulk: "tracked" | "all" | "deleted" | null) => void;
  /** push a change as a new bookmark: generated = templates.git_push_bookmark (push-<short id>); an edited name → --named <name>=@.
   * refused: jj checks its commit like any other (an @ without a description is the normal case) — checkbox disabled until allowed */
  change?: { id: string; generated: string; name?: string; on?: boolean; refused?: PushCommitRefusal | PushCommitRefusal[]; refusedAt?: string };
  onChange?: (change: NonNullable<PushDialogProps["change"]>) => void;
  /** refusals the user allowed → --allow-empty-description / --allow-private / --allow-conflicts (one flag covers every commit) */
  allow?: { emptyDescription?: boolean; private?: boolean; conflicts?: boolean };
  onAllow?: (allow: { emptyDescription?: boolean; private?: boolean; conflicts?: boolean }) => void;
  state?: "ready" | "pushing" | "done";
  /** stops the whole push before anything is sent: network · auth */
  error?: { kind: "network" | "auth"; remote?: string } | null;
  /** 0–1 while pushing; omit for indeterminate */
  progress?: number;
  /** state "done": every ref × remote the push tried */
  results?: PushResult[];
  /** runs the command shown in the footer */
  onPush?: (command: string) => void;
  onCancel?: () => void;
  /** closes the "done" state (default onCancel); the result toast follows */
  onDone?: () => void;
  /** jj git fetch for the remotes whose lease failed */
  onFetch?: () => void;
  onRetry?: () => void;
  closing?: boolean;
  scrim?: boolean;
  width?: number;
}
export declare function PushDialog(props: PushDialogProps): JSX.Element;
export declare namespace PushDialog {
  /** the exact jj git push command for a dialog state ("" = nothing to push) */
  function command(state: { bookmarks?: PushBookmark[]; selected?: string[]; bulk?: string | null; remotes?: string[]; defaultRemotes?: string[]; defaultRemote?: string; change?: PushDialogProps["change"]; allow?: PushDialogProps["allow"] }): string;
  const errors: Record<"network" | "auth", { text: (remote: string) => string }>;
  const outcomes: Record<"pushed" | "lease" | "rejected", { tone: string; icon: string; label: (remote: string) => string; text: (name: string, remote: string, message?: string) => string }>;
}
