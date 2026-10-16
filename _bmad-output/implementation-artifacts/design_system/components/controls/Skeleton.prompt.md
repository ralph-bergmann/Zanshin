Pending placeholder for cards and rows whose shape is known while jj answers (a change being created, a file list loading).

~~~jsx
<Skeleton kind="card" />   {/* jj new — the card exists before its id does */}
<Skeleton kind="row" width={180} />
~~~

- `--skeleton` bars with a `--skeleton-hi` sweep every `--dur-shimmer` (1.6s, linear); the card keeps the real card's material and border. Reduce motion: no sweep.
- Show it only after ~150ms; if the data arrives sooner, nothing flashes.
- Keyboard · VoiceOver · Reduce motion: not focusable · hidden; the region is `aria-busy` · pulses instead of sweeping.
