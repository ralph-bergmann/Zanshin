Count badge — on an `IconButton` (`badge` prop) or at the end of a nav row.

~~~jsx
<IconButton icon="fetch" label="Fetch" badge={3} title="Fetch — jj git fetch · 3 new changes on origin" />
<Badge count={12} tone="neutral" />
~~~

- 15px pill, mono 9.5/700 tabular, cut out of the island by a 2px `--fl-bg-solid` ring. Accent = something to act on (incoming changes); neutral = a plain count.
- Motion: appears .6 → 1 + fade; a changed number rises 5px into place (`--dur-toggle`, glide); 0 → shrinks out (`--dur-exit`). Reduce motion: fades only.
- Keyboard · VoiceOver · Reduce motion: not focusable — the count belongs in its button's label · read with that label · fades only (its scale and rise × `--motion`).
