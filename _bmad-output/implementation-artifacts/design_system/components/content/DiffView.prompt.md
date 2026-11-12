The inspector's diff block — path, layout toggle and "Viewed" over the hunks of one file.

~~~jsx
<DiffView file="lib/onboarding/swipe_controller.dart" viewed={v} onViewedChange={setV}
  tools={<Segmented size="sm" value={mode} onChange={setMode} options={[{ value: "unified", icon: "split-inline", title: "Unified" }, { value: "split", icon: "split-side", title: "Side by side" }]}/>}>
  <DiffHunk oldStart={12} newStart={12} context="class SwipeController" mode={mode} selectable selected lines={["   final double threshold;", "-  void onEnd() {", "+  void onEnd({+DragEndDetails d+}) {"]}/>
</DiffView>
~~~

- Surface: `--code-bg` well, 1px `--fl-border`, 12px radius; JetBrains Mono 11px / 1.65.
- Added lines green on `--add-bg`, removed red on `--rem-bg`, hunk headers in `--hunk` on **`--hunk-bg`** (data — not `--accent-soft`, which is selection). Minus sign is a real "−".
- **Changed words** (Story 10.32): one line per side, each with its sigil, the changed runs in git's delimiters — `[-…-]` only on a removed line, `{+…+}` only on an added one: `"-  static const _kSettle = [-220-];"`, `"+  static const _kSettle = {+260+};"`. A string has no escape: code that holds `[-`, `-]`, `{+` or `+}` (`s[-3:]`, `i++}`) goes in the object form `{ t, s, runs }`, `runs` as `[text, changed]` pairs. The line keeps its faint fill; each changed run lies on the stronger tint of the same hue (`--rem-word-bg` / `--add-word-bg`, the line's full height) and its glyphs turn `--text` (red or green text on a stronger tint falls under 4.5:1 — Control states rule 6). Runs of spaces are marked like any run. A line whose unchanged text is only blanks — an inserted line, a new or deleted file — keeps no marks: its fill says it all. In the app the runs are jj-lib's word diff over pairs of similar lines (Story 5.9: a changed block pairs its removed and added lines first, so unrelated lines no longer share marks; a line without a partner is one changed run and keeps only its fill), painted under the text, so a selection's highlight lies on top of a mark.
- Viewed folds the diff into "Viewed — diff folded away. Click to show it again." — a button whose focus ring sits inside the well (it clips).
- Keyboard · VoiceOver · Reduce motion: the toolbar's controls, each hunk and the folded row are Tab stops · the code is selectable text; word marks are visual only, VoiceOver reads the line's text as before · static.
