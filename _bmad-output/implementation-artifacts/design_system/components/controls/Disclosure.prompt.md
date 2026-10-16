Disclosure for collapsible sections (inspector groups, Projects groups, "Hidden variants").

~~~jsx
<Disclosure label="Changes" meta="4 files" defaultOpen>…FileRows…</Disclosure>
~~~

- 30px header, radius 8, 600 12px `--text-muted`; hover `--fl-hover`, pressed `--fl-on`, focus inside (−2px). Chevron `--text-dim` turns 90° and the body's height and opacity animate together (`--dur-panel` 200ms, glide); the body clips while it moves. Reduce motion: it jumps.
- Space/↩ toggle; → opens, ← closes. VoiceOver: button, expanded/collapsed. `ProjectRow` uses the same chevron timing.
- Keyboard · VoiceOver · Reduce motion: Space / ↩ toggle; → opens, ← closes · button, expanded / collapsed · opens at once (height on `--dur-expand` → 0), the body fades in.
