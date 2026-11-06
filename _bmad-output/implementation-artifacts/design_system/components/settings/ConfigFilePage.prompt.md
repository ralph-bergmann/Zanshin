The config file as text — the GUI half of `jj config edit` (sync #20, Story 11.19): a page inside each Settings tab.

~~~jsx
<ConfigFilePage scope="user" path="~/.config/jj/config.toml" back="General" text={file.text}
  onSave={(text) => bridge.configFileWrite(path, text) /* null · { error: { message, start, end } } */}
  onDirtyChange={setDirty} stale={changedOnDisk} onReload={reload} onBack={() => setPage(null)} />
~~~

- **The way in** — the scope line's **Edit…** (`Link`) after the file it names: General → the user file (`--user`), Project → the repo file (`--repo`), the scope's first file as the CLI picks. The window title becomes "Config file"; the tabs, the scope line and the footer stay.
- **The page takes the window's height** — intro, then the editor well fills the rest (`--code-bg`, `--radius-well`, 1px `--fl-border`, focus ring on focus-within); the Settings window is resizable for long files and long lines.
- **The editor** — the file's exact text, mono `--fs-md` on a 19.5px line, line numbers in a 44px gutter (`--text-faint`), **no wrapping**: long lines scroll sideways. Plain text, no highlighting. A 30px bar above names the file and its state: *Edited* (gold dot) · *✓ Saved* for a moment after a save.
- **Save** (gold primary, ⌘S) · **Revert** (back to the saved file) — both off while nothing changed. Unlike the rest of Settings the file applies only on Save.
- **jj checks before it writes** (the CLI's re-edit loop: an invalid file is never left on disk). A parse error writes nothing and shows: the gutter number in `--rem`, the span underlined (wavy `--rem` over `--rem-bg`), the well's border in `--rem`, and under the well **Not saved: line 15, column 24**, jj's message in mono (verbatim, may span lines), one sentence (*jj only writes a file it can read back. Fix the marked spot, or Revert to the saved file.*) and **Show** (caret to the spot). The message stays until the next Save or Revert.
- **Leaving with edits** — Back (⌘[), the other tab or closing the window asks: `ConfirmDialog` destructive as a sheet on the window, "Discard your edits to config.toml?" · *The file stays as you last saved it.* · **Discard edits**.
- **Changed on disk** while the draft has edits (another window's row, the CLI): a `--warn-bg` notice under the bar, *The file changed on disk while you edited it.* · **Reload** (replaces the draft). Without edits the page just reads the file again. Save still writes the draft, as the CLI's editor would.
- After a save every Settings row and open window reads the file again.
- Keyboard · VoiceOver · Reduce motion: Tab moves focus out of the editor (no tab characters typed); ⌘S saves, ⌘[ goes back · the editor is a text area labelled "Contents of <path>", the error an alert, the disk notice a status · nothing moves.
