Inset text field — settings values, and the summary + details pair used wherever a change is described.

~~~jsx
<TextField size="lg" placeholder="Summary" value={s} onChange={e => setS(e.target.value)}/>
<TextField multiline placeholder="Details (optional)" value={b} onChange={e => setB(e.target.value)}/>
<TextField mono defaultValue="builtin_immutable_heads()" aria-label="Immutable heads revset"/>
~~~

- One way to write a description everywhere: a **Summary** line, then **Details (optional)**. ⌘↩ submits, Esc cancels.
- Well: `rgba(8,10,22,.45)` on night, `rgba(255,255,255,.9)` on paper; 1px `--fl-border`; 8px radius; focus = moon border + 3px `--accent-ring`.
- Placeholders are short nouns, sentence case, no trailing period.
