The **jj log Configurations** window behind *Edit Configurations…* (search menu, View › Edit Configurations… ⌥⌘L) — the only place jj log variants are made, edited and made the default search. **A window of its own**, from the same `Window` scaffold as Settings and Projects — not a sheet: while you write a filter you look things up in the graph and take them from there (authors, bookmark names, change ids).

~~~jsx
<RevsetDialog configs={configs} selected={sel} defaultId={home} me="Ralph Stein" project="zanshin-app" matchCount={12} total={35} dirty={dirty}
  active={key === "configs"} onSelect={setSel} onDefaultChange={setHome} onChange={setConfigs}
  onCancel={close} onApply={apply} onOk={() => { apply(); show(sel); close(); }}/>
~~~

- **Window:** title "jj log Configurations"; 880 × 580 by default, resizable, **minimum 680 × 460**; the list stays 240, the editor grows; size and position are remembered. Traffic lights: close and zoom active, minimise grey. No scrim, no 18px radius, no `--shadow-dialog`, no entrance or exit — the system draws the window.
- **Placement:** it floats above the project window while Zanshin is active (like a tool panel) and moves freely; it closes with the project window. *Edit Configurations…* and ⌥⌘L open it or bring it forward (with its edits as they are).
- **Which project:** the count, `mine()` (the project's identity), Apply and OK refer to the project in the project window (`project`). Switch projects there and count and preview follow; the configurations are global anyway.
- **List** (240px): *Built-in* — `jj log` and `all()` are selectable (read-only detail: the command, "Built-in · …", the command preview with its count); *Custom* — name + expression. Toolbar: add · remove · duplicate · move up / down.
- **Default search:** every entry has a switch row ("Listed first in the search menu — ✕ in the search field returns to it"). The default carries a `Default` tag in the list (16px, outlined in `--border-strong`, no fill). `jj log` is the fallback default: its switch is locked on while it is the default; removing the default configuration falls back to it.
- **Filters:** `is` / `~ not` · function (`author() committer() mine() subject() description() files()`) · mode (contains / is exactly / matches glob / matches regex; files: path or folder / exact file / glob) · value (mono) with `Aa` for case-insensitive. Two or more filters → *Match all `&`* / *Match any `|`*. Dashed chips add a filter.
- **Command:** `❯ jj log -r '…'` — the full command, with "N of M changes match in <project>" and Copy.
- **Footer:** 30px buttons: Cancel · Apply (only when something changed) · **OK** — the gold-tinted primary (moon is never a primary action). The graph's view changes only on OK.
- **Leaving:** Esc, ⌘W and the red button = Cancel. With unsaved changes the window asks first — **"Discard changes?"**, a ConfirmDialog sheet on this window, under its header: *Discard changes* (destructive) · Cancel (keeps editing).
- **Inactive:** a click in the graph makes the project window key and this one inactive (`active={false}`, `tokens/inactive.css`) — it stays where it is.
- `RevsetDialog.exprOf(cfg)` gives the revset a configuration stands for.
- Keyboard · VoiceOver · Reduce motion: focus starts on the selected entry; Tab moves through the window; ↩ outside the fields = OK; Esc / ⌘W = Cancel (asking first when dirty); focus returns to the opener when it closes · a window "jj log Configurations" · nothing animates (the system's window animation follows its settings).
