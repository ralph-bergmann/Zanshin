Inline busy mark for a control or a row that is waiting on jj (12–16px, currentColor).

~~~jsx
<Button size="md" busy>Fetching…</Button>
<span className="row"><Spinner size={12} label="Syncing" /> Syncing with origin…</span>
~~~

- Which loader: **Spinner** inside a control, a row or a toast (< a few seconds, nothing measurable) · **ProgressBar** when progress is measurable (clone, fetch with object counts) — indeterminate only when it isn't · **Skeleton** for cards and rows whose shape is known while their data loads · the **Nami loader** only for the window itself (splash, opening a repository) when there is nothing else to show for more than ~1s.
- One turn per `--dur-spin` (800ms), linear; it keeps turning with reduce motion on.
- Keyboard · VoiceOver · Reduce motion: not focusable · progressbar "busy" when it stands alone (with `label`), else hidden (the button is `aria-busy`) · keeps turning — it is information, as NSProgressIndicator.
