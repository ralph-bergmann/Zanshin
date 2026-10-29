The drag chip that follows the pointer during direct manipulation (rebase by drag, move a bookmark, move a file or hunk, move a row of the Projects tree).

~~~jsx
<DragGhost id="ovknlmro" workingCopy subject="(no description set)" command="jj rebase -s ovknlmro -o vruxwmqv"/>
<DragGhost kind="bookmark" bookmark="ZAN-412" rest="onboarding-swipe-gestures" hint="Drop on the change it should point to"/>
<DragGhost kind="diff" status="M" label="swipe_controller.dart" added={42} removed={7} hint="Drop on the change it belongs to"/>
<DragGhost kind="project" status="clean" label="dotfiles" target="Into Backend"/>
~~~

- Chip: 34px, `--card-solid-hi`, moon border + 3px ring, tilted −1.5°. Offset 14px / 12px from the pointer.
- Under it, the command a plain drop would run (moon border) — or the hint while nothing is targeted.
- A list move runs no jj command: `kind="project"` (status dot) / `"group"` (folder) with the name as `label`, and `target` says where it goes in plain words (moon border, sans): "Into Backend", "To the top level"; the hint "Drop between rows or on a group" while nothing valid is under the pointer.
- Items keep the arrow cursor while dragging (Finder does); only a held canvas shows the closed hand.
- Keyboard · VoiceOver · Reduce motion: follows the pointer only; Esc cancels the drag · hidden (the drop menu is announced) · no tilt animation, it simply follows.
