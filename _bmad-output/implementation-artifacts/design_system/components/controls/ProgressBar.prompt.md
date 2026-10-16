Progress bar for operations that can measure themselves (clone, fetch with object counts, rebasing many changes).

~~~jsx
<ProgressBar label="Fetching" value={412} max={1280} />
<ProgressBar label="Connecting to origin" />   {/* indeterminate */}
~~~

- 4px, radius 2, `--track` behind an `--accent` fill. Value changes ease (`--dur-panel`, glide). Indeterminate: a 32% segment sweeps every `--dur-shimmer` (1.6s); with reduce motion it becomes a still, half-strength full bar.
- Put the numbers next to it in mono (`412 / 1,280 objects`), not inside it.
- Keyboard · VoiceOver · Reduce motion: not focusable · progressbar with value (determinate) or "in progress" · the value jumps (`--dur-expand` → 0); indeterminate: the fill spans the groove and pulses.
