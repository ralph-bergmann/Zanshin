Confirmation for the few things `jj undo` can't take back. Local edits never ask: they act and show the undo toast. Pushing has its own sheet (`PushDialog`).

~~~jsx
<ConfirmDialog title="Clear the operation history?" confirmLabel="Clear history" onConfirm={run} onCancel={close} cmd="jj op abandon ..@-">
  Every operation before the current one leaves the operation log. <code>jj undo</code> and the Undo Timeline can’t go back past this point. Your changes stay as they are.
</ConfirmDialog>
~~~

- Title is the question, sentence case, ends with "?". Body says what changes and what can't be recovered; ids and commands in mono. The button repeats the verb ("Clear history", never "OK" or "Yes"). The command well shows the exact command — one real `jj` command, never a sequence the UI made up.
- destructive: `Button variant="destructive"` is the one primary (gold steps aside); focus starts on Cancel; ↩ presses the focused button, ⌘↩ confirms, Esc cancels. warn/default: gold primary, focused, ↩ confirms (warn adds the `conflict` mark in `--warn` to the title).
- The 18px modal sheet over the blurred scrim; in = `--dur-dialog` glide from 8px below at .985; out = `closing`: the scrim fades, the sheet drops 4px (`--dur-exit-lg`, `--ease-exit`). While it runs: `busy`.
- Keyboard · VoiceOver · Reduce motion: focus starts on Cancel (destructive) or the primary; Tab cycles inside; Esc and Cancel cancel, a click on the scrim does nothing; focus returns to the opener · alertdialog, labelled by the title, described by the body · fades only.
