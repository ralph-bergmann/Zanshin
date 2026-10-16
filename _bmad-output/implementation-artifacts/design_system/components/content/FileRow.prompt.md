One changed file in a change's file list; the path truncates from the left so the filename stays visible.

~~~jsx
<FileRow status="M" path="lib/onboarding/swipe_controller.dart" added={42} removed={7} selected />
~~~

- A neutral row: rest transparent · hover `--fl-hover` · pressed `--fl-on` · **on** (its diff shows) `--fl-on` → on + hover `--fl-on-hover` → on + pressed `--fl-press` · viewed dims the path to .55 and shows the green check · lifted (being dragged) .38 with a dashed accent outline · focus inside (−2px; the panel clips).
- Secondary text on a fill steps up a rung (counts and path stay ≥ 4.5:1 on the pressed row).
- Keyboard · VoiceOver · Reduce motion: the list is one Tab stop, ↑ ↓ move and show that file's diff, Space toggles its checkbox when `selectable`, ↩ jumps to the diff · button "path, modified, 42 added, 7 removed", selected · colour only.
