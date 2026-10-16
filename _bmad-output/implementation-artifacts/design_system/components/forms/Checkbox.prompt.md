Checkbox for selecting files and hunks; `mixed` when only some hunks of a file are in.

~~~jsx
<Checkbox checked={sel} onChange={setSel} label="Select hunk" />
<Checkbox mixed label="Select swipe_controller.dart" />
<button className="zs-viewed is-on"><Checkbox presentational size="sm" tone="add" checked /> Viewed</button>
~~~

- One component, not two: the Viewed toggle is this checkbox at `size="sm"` (13px, radius 3.5) in `tone="add"` — green because Viewed is a review state (data), not a selection.
- States: hover brightens the box edge; pressed adds `--fl-on`; on/mixed fill `--accent` with an `--accent-ink` mark; on + hover lays `--fill-on-hover` over the fill; disabled .4; focus = the 2px ring.
- Motion: the check draws in over `--dur-toggle` (180ms) on `--ease-glide`; check ↔ mixed moves the same three points; unchecking clears at once while the fill fades (`--dur-hover`). Reduce motion: no draw, no morph.
- Space toggles; VoiceOver: checkbox, "mixed" when partial.
- Keyboard · VoiceOver · Reduce motion: a Tab stop; Space toggles · checkbox, "mixed" when partial · the check is simply there (its draw is movement → 0), the fill fades.
