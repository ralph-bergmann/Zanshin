Selection checkbox for files and hunks in the inspector — the moon accent, never gold.

~~~jsx
<Checkbox checked={all} mixed={some} onChange={toggleAll} label="Select all"/>
<Checkbox checked={sel.has(h.id)} onChange={() => toggle(h.id)} label="Select hunk"/>
~~~

- 15px, 4.5px radius, 1.5px `--text-faint` border; on/mixed fill `--accent` with `--accent-ink` mark.
- Only shown where a change can still be rewritten (mutable). Immutable history has nothing to select.
- Use `Switch` for settings, not a checkbox.
