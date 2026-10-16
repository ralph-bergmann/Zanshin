Chips for rule-building and filters (jj log Configurations: "~" NOT, "Aa" match case, "+ author"; active filters over a list; the Push sheet's remotes).

~~~jsx
<Chip kind="not" mono on={not} onChange={setNot} title="Exclude matches — ~">~</Chip>
<Chip kind="toggle" mono on={cs} onChange={setCs} title="Match case">Aa</Chip>
<Chip kind="add" mono onClick={addRule}>author</Chip>
<Chip kind="filter" mono onRemove={drop}>author(“Lena”)</Chip>
~~~

- 26px (sm 22), radius 7 (add: pill, dashed `--border-strong`). Neutral: rest `--fl-hover` · hover `--fl-on` · pressed `--fl-press` · focus = the 2px ring · disabled .4.
- **On states are tinted:** toggle on = `--accent-soft` + `--accent-text` → hover `--accent-soft-hi` → pressed `--accent-ring`, the label turns `--text` on both (accent text keeps 4.5:1 only on the plain tint). not on = `--rem-bg` + `--rem` → hover `--rem-bg-hover` → pressed `--rem-bg-press`, label `--text` — negation is red because it removes matches. add = dashed until hover, then solid; pressed `--fl-on`.
- The Configurations dialog's `.zs-rsd-not`, `.zs-rsd-ci` and `.zs-rsd-chip` follow these kinds.
- Keyboard · VoiceOver · Reduce motion: a Tab stop each; Space / ↩ toggle; the filter chip's ✕ is its own Tab stop, Delete / Backspace on the chip removes it · toggle: a button with `aria-pressed`; filter: its value, ✕ labelled "Remove …" · colour only — nothing moves.
