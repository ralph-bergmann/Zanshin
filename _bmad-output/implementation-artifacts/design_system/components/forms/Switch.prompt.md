Binary setting that applies immediately (detailed cards, group stacks, the Default search row).

~~~jsx
<OptionRow label="Group stacks"><Switch label="Group stacks" checked={stacks} onChange={setStacks} /></OptionRow>
~~~

- 30 × 18. Off: `--bg-card-2` track, 1px `--border-strong`, knob `--text-dim`. Hover: the edge borrows `--edge-hov` (the one hover edge of cards, bookmark chips and the switch), knob `--text-muted`. On: `--accent` track, `--accent-line` edge, `--accent-ink` knob; on + hover lays `--fill-on-hover` over it. Pressed: the knob stretches 12 → 15px toward its travel. Disabled .4; reason → aria-disabled + a wrapper with the reason (base.css › disabled).
- Motion: the knob slides on `--dur-toggle` (glide); every colour fades on `--dur-hover` — never on the toggle duration.
- Keyboard · VoiceOver · Reduce motion: Tab stop; Space toggles (↩ too, as macOS) · switch, on / off, labelled by `label` · the knob is simply there (`--dur-toggle` → 0), the colour still fades.
