The inspector's diff block — path, layout toggle and "Viewed" over the hunks of one file.

~~~jsx
<DiffView file="lib/onboarding/swipe_controller.dart" viewed={v} onViewedChange={setV}
  tools={<Segmented size="sm" value={mode} onChange={setMode} options={[{ value: "unified", icon: "split-inline", title: "Unified" }, { value: "split", icon: "split-side", title: "Side by side" }]}/>}>
  <DiffHunk oldStart={12} newStart={12} context="class SwipeController" mode={mode} selectable selected lines={["   final double threshold;", "-  void onEnd() {", "+  void onEnd(DragEndDetails d) {"]}/>
</DiffView>
~~~

- Surface: `--code-bg` well, 1px `--fl-border`, 12px radius; JetBrains Mono 11px / 1.65.
- Added lines green on `--add-bg`, removed red on `--rem-bg`, hunk headers in `--hunk` on **`--hunk-bg`** (data — not `--accent-soft`, which is selection). Minus sign is a real "−".
- Viewed folds the diff into "Viewed — diff folded away. Click to show it again." — a button whose focus ring sits inside the well (it clips).
- Keyboard · VoiceOver · Reduce motion: the toolbar's controls, each hunk and the folded row are Tab stops · the code is selectable text · static.
