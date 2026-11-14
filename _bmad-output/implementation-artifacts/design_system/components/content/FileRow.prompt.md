One changed file in a change's file list, name first (Story 10.39): the file's name never cut while folder text is left, then its folder dimmed and cut in its middle.

~~~jsx
<FileRow status="M" path="packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart" added={42} removed={7} selected />
<FileRow tree depth={1} status="A" path="lib/onboarding/swipe_controller.dart" added={12} />
<FileRow open depth={0} name="packages/logic_designer/lib/src" count={3} selectable mixed added={54} removed={7} />
~~~

- 28 high. Status badge 17 px square: M, R `--accent-soft` / `--accent`; A, C `--add-bg` / `--add`; D `--rem-bg` / `--rem`. The name in `--text`; the folder with its `/` in `--text-faint`, its head (everything up to the last folder) giving way first, then the last folder, then the name, each with its own ellipsis. A rename shows its new name and folder; the tooltip is the path (`old → new` for a rename).
- A neutral row: rest transparent · hover `--fl-hover` · pressed `--fl-on` · **on** (its diff shows) `--fl-on` → on + hover `--fl-on-hover` → on + pressed `--fl-press` · viewed dims name and folder to .55 and shows the green check · lifted (being dragged) .38 with a dashed accent outline · focus inside (−2px; the panel clips).
- Tree (`tree`): the name only, indented 8 + 14 × depth + 18. A folder row (`open`): chevron, three-state checkbox (picks or unpicks all its files; mixed when some), folder glyph, the name (a folder holding only one folder joins with it: `a/b/c`), a 10 px count pill on `--fl-hover` in `--text-dim`, its files' summed counts; indented 8 + 14 × depth. Folders sort by name, then files by name; flat keeps jj's order.
- Keyboard · VoiceOver · Reduce motion: the list is one Tab stop, ↑ ↓ move and show that file's diff (a folder only becomes current), ← collapses an open folder or goes to the parent folder, → expands or goes to the first child, ↩ toggles a folder, Space toggles the checkbox when `selectable` (a folder's: all its files), V marks Viewed, ⌘C copies the absolute path · a right-click opens the row's menu (Open in Editor, Reveal in Finder, Copy path, Copy relative path) · button "path, modified, 42 added, 7 removed", selected · colour only.
