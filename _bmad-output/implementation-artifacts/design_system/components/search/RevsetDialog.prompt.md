The configurations dialog behind *Edit Configurations…* in the search menu — the only place jj log variants are made, edited and made the default search.

~~~jsx
<RevsetDialog overlay configs={configs} selected={sel} defaultId={home} me="Ralph Stein" matchCount={12} total={35} dirty={dirty}
  onSelect={setSel} onDefaultChange={setHome} onChange={setConfigs}
  onCancel={close} onApply={apply} onOk={() => { apply(); show(sel); close(); }} onClose={close}/>
~~~

- **List** (240px): *Built-in* — `jj log` and `all()` are selectable (read-only detail: the command, "Built-in · …", the command preview with its count); *Custom* — name + expression. Toolbar: add · remove · duplicate · move up / down.
- **Default search:** every entry has a switch row ("Listed first in the search menu — ✕ in the search field returns to it"). The default carries a `Default` tag in the list (16px, outlined in `--border-strong`, no fill). `jj log` is the fallback default: its switch is locked on while it is the default ("Used whenever no other configuration is the default"); removing the default configuration falls back to it.
- **Filters:** `is` / `~ not` · function (`author() committer() mine() subject() description() files()`) · mode (contains / is exactly / matches glob / matches regex; files: path or folder / exact file / glob) · value (mono) with `Aa` for case-insensitive. Two or more filters → *Match all `&`* / *Match any `|`*. Dashed chips add a filter.
- **Command:** `❯ jj log -r '…'` — the full command, with "N of M changes match" and Copy.
- **Material:** the same glass dialog as Settings and Projects — scrim `rgba(7,9,20,.48)` + `blur(12px) saturate(1.2)`, sheet radius 18 on `--fl-sheen` + `--fl-bg-solid`, `--fl-border` dividers, title 17/600; transparent sidebar with caps section labels, the selected entry in moon; glass fields; the Default search row is a settings row (`--fl-hover`, radius 12); the command preview is a well like the diff block.
- **Buttons:** 32px, radius 9, `--fl-hover`: Cancel · Apply (only when something changed) · **OK** — the gold-tinted primary, as in Projects and the inspector (moon is never a primary action).
- `RevsetDialog.exprOf(cfg)` gives the revset a configuration stands for.
