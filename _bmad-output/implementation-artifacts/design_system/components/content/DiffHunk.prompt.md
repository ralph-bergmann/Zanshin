One hunk inside a `DiffView`: header with checkbox, range, context and counts; color-words lines unified or side by side.

~~~jsx
<DiffHunk context="Future<Response> push(Batch b)" selectable selected={sel} onToggle={setSel}
  lines={[" 58:58|  final res = await _http.post(_url, body: b.encode());", "~59:59|  if (res.statusCode [-!= 200-]{+== 409 && attempt < 3+}) {"]}/>
~~~

- Header: 30px on **`--hunk-bg`** (moon as data — it never follows the accent); range in `--hunk` mono. Selected → the header takes `--accent-soft-hi` (text `--text`) and every line a 2px `--accent-line` edge — selection is the accent, the hunk band is data, and the two stay apart in every family. The counts are the distinct new (+) and old (−) line numbers of its changed lines.
- Selection drives the composer: on @ it becomes `jj commit`, elsewhere `jj split -r`.
- `onGrab` makes the header a drag handle (grip appears on hover) — drop it on another change to move the hunk.
- Lines are written as in `DiffView` (`"<kind><left>:<right>|<text>"`, changed words in `[-…-]` / `{+…+}`, removed runs on `--rem-word-bg`, added runs on `--add-word-bg`; the removed tint is darker than the added one); git-sigil lines still work and are numbered from `oldStart` / `newStart`. `marks="words"` draws Zanshin's whole-word style (DiffView › Two word-mark styles): a mark exactly where a run says so.
- **Side by side** (Story 5.10) is rebuilt from the same lines, so each side shows whole lines: a context line is one row; in a run of changed lines the left cells are the old lines (each old number once, its equal and removed runs joined — one old line spread over several new ones shows once, whole), the right cells the new lines, paired row by row; each cell shows its number; a conflict header spans the row.
- Keyboard · VoiceOver · Reduce motion: the hunk is a Tab stop with its ring inside; Space toggles its checkbox; the diff text is selectable (the numbers are not; Flutter paints only the highlight there — readme › Text selection) · group "Hunk 58–64, selected", lines read as context / removed / added / changed; word marks are visual only, VoiceOver reads the line's text as before · static (the grip fades).
