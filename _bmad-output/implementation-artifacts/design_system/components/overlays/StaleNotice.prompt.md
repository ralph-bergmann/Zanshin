**Working copy is stale** — the project-level state when another workspace or the CLI rewrote this workspace's `@` (for example by rebasing one of its ancestors). jj then refuses everything that reads the working copy — `jj log` too, and the workspace list — until `jj workspace update-stale` runs. With several workspaces this is not an edge case.

~~~jsx
<StaleNotice onCopy={copy} />                         {/* notice only */}
<StaleNotice onUpdate={() => run("jj workspace update-stale")} />   {/* later: with the action */}
~~~

- **Where:** a glass island top-centre over the graph, 12px under the top bar (`--chrome-top`), on `--z-chrome`; it stays as long as the state lasts. Not in a menu (the menu's data would be refused too), not a toast (it isn't an event).
- **The graph keeps its last valid layout**, as after a revset error; operations that need the working copy are disabled with the reason "Working copy is stale". The project capsule's status dot turns `--warn` (title: the same sentence).
- **One sentence and the command that fixes it:** "Working copy is stale · `jj workspace update-stale`". No Retry — retrying can't help.
- **With the action** (when the app offers it): "Update working copy" — a quiet 30px button with the command in its tooltip; while it runs, busy; then the usual result toast ("Updated the working copy · Undo").
- Material: `--fl-sheen` over `--fl-bg` glass, 1px `--fl-border`, `--fl-shadow`, radius pill, 44px high (`--control-xl`, the bar's height); the mark `conflict` in `--warn`, the sentence `--text` 500, the command mono `--text-muted`.
- Keyboard · VoiceOver · Reduce motion: the action (or Copy) is a Tab stop after the top bar · role status — announced once when the state begins · it fades in (`--dur-panel`), no movement.
