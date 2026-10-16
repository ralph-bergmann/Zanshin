import React from "react";
import { Icon } from "../brand/Icon.jsx";
import { Button } from "../actions/Button.jsx";
import { IconButton } from "../actions/IconButton.jsx";

// StaleNotice — the project-level state "Working copy is stale": another workspace or the CLI rewrote this workspace's @ (say, by
// rebasing an ancestor) and jj refuses everything that reads the working copy — jj log included, and the workspace list — until
// `jj workspace update-stale` runs. Not a menu, not a toast: a glass island top-centre over the graph, under the top bar, while it lasts.
// The graph keeps its last valid layout (as with a revset error); the project capsule's dot turns warn. No Retry — retrying can't help.
// Without onUpdate: the sentence and the command (copyable). With onUpdate: "Update working copy" — the command in its tooltip, then the
// usual result toast.
export function StaleNotice({ command = "jj workspace update-stale", onUpdate, onCopy, busy = false, className = "", style }) {
  return (
    <div role="status" className={("zs-stale " + className).trim()} style={style}>
      <Icon name="conflict" size="md" className="zs-stale-ic" />
      <span className="zs-stale-t">Working copy is stale</span>
      <span className="zs-stale-sep" aria-hidden="true">·</span>
      <code className="zs-stale-cmd">{command}</code>
      {onUpdate ? <Button size="md" icon="fetch" busy={busy} title={command} onClick={onUpdate}>Update working copy</Button>
        : <IconButton size="sm" icon="copy" iconSize="sm" label="Copy command" title={"Copy — " + command} onClick={onCopy} />}
    </div>
  );
}
