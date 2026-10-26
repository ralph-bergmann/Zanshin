The system's window buttons, as a mock for cards and the UI kit. In the app AppKit draws them; Zanshin never moves them.

~~~jsx
<TrafficLights />                                   {/* the project window */}
<TrafficLights buttons={{ close: true }} />         {/* Settings: minimise and zoom greyed */}
<TrafficLights buttons={{ close: true, zoom: true }} /> {/* Projects */}
~~~

- **Geometry is the system's, read at runtime** (`NSWindow.standardWindowButton(…).frame`). Reference (macOS 27.0.1, standard buttons, the app's toolbar): 14 × 14pt, pitch 23, the block 60 wide at x 19–79, centre y 26. Without a toolbar: x 9–69, y 16. Before macOS 26: 12pt at a 20pt pitch. The rule is relative, so it holds on every version: the top bar's first island starts at **block end + 12** and the bar centres on **the block's centre line**; content starts at bar bottom + 12. Full screen: the buttons leave with the menu bar → first island at 12, bar at 12, content at 68.
- **The deviation (a Zanshin decision, not the system default):** at rest the app hides the system buttons and draws grey rings (`TrafficLightOverlayView`, `--tl-ring`, 1px) — for disabled buttons too. Hovering the group brings back the system's buttons: enabled ones in colour with their symbols, disabled ones greyed (`--tl-idle`). Pressing darkens. No glow.
- **Inactive window:** the rings, as at rest; hover still shows the colours (the system does the same).
- Keyboard · VoiceOver · Reduce motion: the system's buttons (VoiceOver reads close / minimise / zoom, "dimmed" when disabled; ⌘W, ⌘M and the Window menu are the keyboard path) · the rings are decoration and hidden from VoiceOver · nothing moves.
- **The floating client** (sync #10) uses this mock — rings at rest, the system's colours and symbols on hover, `--tl-idle` for greyed buttons, darker on press, no glow. Its Settings and Projects windows sit at the reference geometry (14px, pitch 23, x 19, centre y 26); its **project window keeps the pre-A2 geometry** (12px at a 20px pitch, x 12–64, centred on the 44px bar at y 34), so its buttons are 2px smaller there until it adopts A2 (first island 91, bar 4–48, content 60).
