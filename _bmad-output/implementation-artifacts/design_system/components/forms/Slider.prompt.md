Slider for continuous view settings (Card width); value readout in mono.

~~~jsx
<Slider label="Card width" min={160} max={400} step={10} value={w} unit="px" onChange={setW} />
<Slider label="Context lines" min={0} max={10} step={1} value={n} ticks onChange={setN} />
~~~

- Track 4px `--track` (hover `--track-hover`); the fill is **`--accent-line`** (the light paper families' fill would vanish on the track; the thumb carries the value anyway).
- Thumb: `--thumb` with a 1px `--thumb-edge` (white on paper needs it for 3:1) and `--thumb-shadow`; hover deepens the shadow; drag adds a 5px `--accent-ring` halo at once. **Focus is the one rule drawn around the thumb:** a `--focus-offset` gap in the card colour, then a `--focus-w` ring in `--focus-ring` (3px under increased contrast) — no literal ring.
- **The value never tweens:** dragging follows the pointer; a click on the track jumps the thumb to that point and the press continues as a drag; key steps land at once. (`--dur-toggle` is not the slider's.) The readout follows instantly (tabular figures, width never jumps) and turns `--text` while dragging.
- Ticks (1 × 3px, `--tick`) only for stepped values with ≤ 21 steps. Disabled .4.
- Keyboard · VoiceOver · Reduce motion: one Tab stop · ← ↓ one step down, → ↑ one step up · Page Down / Page Up ten steps (at most to the ends) · Home / End min / max · slider with value + unit ("240 px") · nothing animates anyway.
