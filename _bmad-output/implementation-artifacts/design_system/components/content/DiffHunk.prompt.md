One hunk inside a `DiffView`: header with checkbox, range, context and counts; lines unified or side by side.

~~~jsx
<DiffHunk oldStart={58} newStart={58} context="Future<Response> push(Batch b)" selectable selected={sel} onToggle={setSel}
  lines={["   final res = await _http.post(_url, body: b.encode());", "-  if (res.statusCode != 200) throw SyncError(res);", "+  if (res.statusCode == 409 && attempt < 3) {"]}/>
~~~

- Header: 30px on **`--hunk-bg`** (moon as data — it never follows the accent); range in `--hunk` mono. Selected → the header takes `--accent-soft-hi` (text `--text`) and every line a 2px `--accent-line` edge — selection is the accent, the hunk band is data, and the two stay apart in every family.
- Selection drives the composer: on @ it becomes `jj commit`, elsewhere `jj split -r`.
- `onGrab` makes the header a drag handle (grip appears on hover) — drop it on another change to move the hunk.
- Changed words are written and marked as in `DiffView`: one line per side with its sigil, `[-…-]` only on a removed line and `{+…+}` only on an added one (`"-  static const _kSettle = [-220-];"`, `"+  static const _kSettle = {+260+};"`); code that holds those character pairs goes in the object form `{ t, s, runs }`. The stronger tint under the run, `--text` glyphs, none on a line whose unchanged text is only blanks — in both modes; a side-by-side cell clips its marks.
- Keyboard · VoiceOver · Reduce motion: the hunk is a Tab stop with its ring inside; Space toggles its checkbox; the diff text is selectable (Flutter paints only the highlight there — readme › Text selection) · group "Hunk 58–64, selected", lines read as added / removed; word marks are visual only, VoiceOver reads the line's text as before · static (the grip fades).
