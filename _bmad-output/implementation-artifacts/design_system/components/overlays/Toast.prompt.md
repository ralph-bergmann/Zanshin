The undo toast that follows every graph edit (drop, squash, split, commit, abandon, push), plus its refusal and failure variants.

~~~jsx
<Toast onUndo={undo} onClose={dismiss}>Moved <ChangeId id="ovknlmro" length={8}/> onto <ChangeId id="vruxwmqv" length={8}/></Toast>
<Toast tone="warn" onClose={dismiss}>Can’t move <ChangeId id="ovknlmro" length={8}/> onto its own descendant</Toast>
<Toast tone="error" action={{ label: "Retry", onClick: retry, title: "jj git fetch" }} onClose={dismiss}>Fetch failed — origin is unreachable</Toast>
~~~

- Past-tense verb first, then the ids: "Squashed … into …", "Inserted … after …", "Abandoned …", "Committed … · “msg”", "Pushed 2 bookmarks to origin". Refusals say what didn't happen and why; failures say what failed — no "please", no exclamation marks.
- 36px glass pill (`--control-lg`), bottom centre, 20px from the edge; Undo / Redo / Retry are 26px quiet pills (`--control-sm`; hover `--fl-on`, pressed `--fl-press`), × dismisses. Warn: `conflict` glyph in `--warn`; error: `alert` glyph in `--rem`, role alert.
- Timing: success and warn hide after `--dur-toast-hold` (6.5s, paused while hovered); error stays until dismissed or retried.
- Motion: in = rise 10px + fade (`--dur-slide`, glide). Out = 8px down + fade (`--dur-exit-lg`, `--ease-exit`). A replaced toast fades in place (`--dur-exit`). Reduce motion: fades only (the distances × `--motion`).
- One toast at a time; a new one replaces the current and the timer restarts.
- **After a conversion** (sync #19): when local bookmarks have an untracked remote counterpart (the CLI's post-`jj git init` hint), the "Opened" toast takes the warn tone and names them (*main@origin isn't tracked* / *3 remote bookmarks aren't tracked*; jj's hint and a plain explanation as tooltip) with one action: **Track** (`jj bookmark track main@origin`) or **Track all** (the CLI's single `jj bookmark track a@origin b@origin …`).
- **Undo, three places.** The toast's Undo takes back the operation it reports. **⌘Z** (Edit › "Undo ‹action›", the item names it) takes back Zanshin's own last operation — only while it is still the current one; then a toast "Undid … · Redo" (⇧⌘Z redoes). ⌘Z never goes further back and never over someone else's operation (the CLI, another workspace). Everything older is the **Undo Timeline**, where you see what you take back. Undoing a push warns as the CLI does: *Undoing a push operation often leads to conflicted bookmarks.* · Redo.
- Keyboard · VoiceOver · Reduce motion: not in the Tab order while you work — ⌘Z is its key; Undo and × are buttons when reached with Tab (F6 moves to the toast region) · status (alert for errors), announced once · fades only.
