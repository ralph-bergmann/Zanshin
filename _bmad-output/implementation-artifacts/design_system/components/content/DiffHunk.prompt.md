One hunk inside a `DiffView`: header with checkbox, range, context and counts; lines unified or side by side.

~~~jsx
<DiffHunk oldStart={58} newStart={58} context="Future<Response> push(Batch b)" selectable selected={sel} onToggle={setSel}
  lines={["   final res = await _http.post(_url, body: b.encode());", "-  if (res.statusCode != 200) throw SyncError(res);", "+  if (res.statusCode == 409 && attempt < 3) {"]}/>
~~~

- Header: 30px, `--accent-soft` fill; range in `--hunk` mono; selected → 24% moon fill and a 2px moon edge on every line.
- Selection drives the composer: on @ it becomes `jj commit`, elsewhere `jj split -r`.
- `onGrab` makes the header a drag handle (grip appears on hover) — drop it on another change to move the hunk.
