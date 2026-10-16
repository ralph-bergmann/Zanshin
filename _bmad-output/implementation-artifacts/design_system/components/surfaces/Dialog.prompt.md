A modal **sheet** over the project window for short modal tasks — the OK / Cancel kind. There are two: ConfirmDialog and Push. Settings, Projects and jj log Configurations are not sheets: they are windows of their own (`Window`).

~~~jsx
<Dialog title="Rename bookmark" onClose={cancel} width={420} height="auto" initialFocus="input">…</Dialog>
~~~

- Material: the 18px sheet (`--radius-dialog`) on `--fl-sheen` over `--fl-bg-solid`, `--shadow-dialog`, over `--scrim` + 12px blur, on `--z-dialog`. In: `--dur-dialog` on glide; out (`closing`): the scrim fades, the sheet drops 4px (`--dur-exit-lg`, `--ease-exit`). One gold primary.
- Keyboard · VoiceOver · Reduce motion: Esc (and Cancel / ✕) call `onClose`; **a click on the scrim does nothing** — a macOS sheet never closes by a click beside it, and unsaved input would go without asking · focus starts on `initialFocus` (a selector) or the first control, Tab / ⇧Tab stay inside the sheet (focus trap), and on close focus returns to what had it before (`useSheetFocus`, shared by every sheet) · dialog, `aria-modal`, labelled by the title · the sheet only fades (its 8px rise and scale are × `--motion`).
