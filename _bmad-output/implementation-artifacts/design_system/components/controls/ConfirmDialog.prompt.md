Confirmation for the few things `jj undo` can't take back. Local edits never ask: they act and show the undo toast. Pushing has its own sheet (`PushDialog`).

~~~jsx
<ConfirmDialog title="Clear the operation history?" confirmLabel="Clear history" onConfirm={run} onCancel={close} cmd="jj op abandon ..@-">
  Every operation before the current one leaves the operation log. <code>jj undo</code> and the Undo Timeline can’t go back past this point. Your changes stay as they are.
</ConfirmDialog>
~~~

- Title is the question, sentence case, ends with "?". Body says what changes and what can't be recovered; ids and commands in mono. The button repeats the verb ("Clear history", never "OK" or "Yes"). The command well shows the exact command — one real `jj` command, never a sequence the UI made up. The one exception is `choices`: when one decision runs different commands (deleting a bookmark that a remote tracks), each choice row shows its own commands, one per line, in the order they run — each a real `jj` command, and exactly what the choice runs.
- `choices` (Story 10.44): a radio group of rows (padding 10 12, `--radius-card`, `--fl-on` chosen, `--fl-hover` on hover), each the label (500 `--fs-control`, "default" in `--fs-xs` `--text-faint` beside the one chosen at open), its commands (mono `--fs-sm`/1.5, `--text-muted`) and a note on what undo can do (`--fs-id`/1.4, `--text-dim`); a `danger` row (it can't be undone) in `--rem`. Default to the middle, reversible choice; replaces `cmd`.

~~~jsx
<ConfirmDialog title="Delete feature/auth-flow?" confirmLabel="Delete" defaultValue="push" onConfirm={run} onCancel={close}
  choices={[
    { id: "here", label: "Only here — keep it on origin", cmd: ["jj bookmark forget feature/auth-flow"], note: "Undo works. origin keeps it; it stays here as an untracked remote bookmark." },
    { id: "push", label: "Here, and on origin when you push the deletion", cmd: ["jj bookmark delete feature/auth-flow"], note: "Undo works until you push. A plain push skips deletions; the Push sheet offers to push them." },
    { id: "now", label: "Here and on origin now", cmd: ["jj bookmark delete feature/auth-flow", "jj git push --remote origin --bookmark feature/auth-flow"], note: "Can't be undone: origin loses the bookmark.", danger: true },
  ]}>
  The bookmark is also on origin. Where should it go?
</ConfirmDialog>
~~~
- destructive: `Button variant="destructive"` is the one primary (gold steps aside); focus starts on Cancel; ↩ presses the focused button, ⌘↩ confirms, Esc cancels. warn/default: gold primary, focused, ↩ confirms (warn adds the `conflict` mark in `--warn` to the title).
- The 18px modal sheet over the blurred scrim; in = `--dur-dialog` glide from 8px below at .985; out = `closing`: the scrim fades, the sheet drops 4px (`--dur-exit-lg`, `--ease-exit`). While it runs: `busy`.
- Keyboard · VoiceOver · Reduce motion: focus starts on Cancel (destructive) or the primary; Tab cycles inside; Esc and Cancel cancel, a click on the scrim does nothing; focus returns to the opener · alertdialog, labelled by the title, described by the body · fades only.
