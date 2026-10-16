The menu that opens over a change while something is dragged onto it — offering only what makes sense for that source and target.

~~~jsx
<DropMenu place="below" active={0} items={[
  { id: "onto", group: "move", icon: "move-onto", label: "Move here", hint: "rebase -s", cmd: "jj rebase -s ovknlmro -o vruxwmqv" },
  { id: "after", group: "place", icon: "insert-after", label: "Insert after", hint: "rebase -A", cmd: "jj rebase -r ovknlmro -A vruxwmqv" },
  { id: "squash", group: "combine", icon: "squash-into", label: "Squash into this change", hint: "squash", cmd: "jj squash --from ovknlmro --into vruxwmqv" },
]}/>
~~~

- Priority order; the first item is what a plain drop does. Above the card the list runs bottom-up so it stays nearest.
- Hover highlight is the moon accent with `--accent-ink`; the footer always shows the exact jj command of the highlighted action.
- Labels: verb first, sentence case ("Move only this change", "Into a new change after"). Warnings go in `note` ("backwards").
- Every applied drop ends in an undo `Toast`.
- Keyboard · VoiceOver · Reduce motion: during a drag ↑ ↓ move the default action, Esc cancels the drag, releasing over the card runs the highlighted row · menu, announced when it opens · fades in (its scale × `--motion`).
