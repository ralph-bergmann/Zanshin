Scroll container for panels, lists and menus taller than their space (Projects tree, inspector, search suggestions).

~~~jsx
<ScrollArea height={320} label="Projects">{rows}</ScrollArea>
<ScrollArea height={240} axis="both">{wideDiff}</ScrollArea>
~~~

- Overlay, never a gutter that takes width. Rest: hidden. Scrolling: the `--scroll-thumb` (6px pill, 4px from the edge) fades in (`--dur-hover`) and fades out `--delay-scroll-hide` (800ms) after the last scroll. `axis="both"` adds the same bar along the bottom.
- Pointer within the 14px gutter: the `--scroll-track` appears and the thumb widens to 10px (`--scroll-thumb-hover`, `--dur-nudge` on glide). Dragging: `--scroll-thumb-drag`. Thumb ≥ 24px.
- **Click in the track:** one page toward the click — macOS's default "Jump to the next page"; with the system setting "Jump to the spot that's clicked" (`pageJump={false}`, Flutter: `AppleScrollerPagingBehavior`) it jumps there. ⌥-click does the other. The press can continue as a drag.
- **Overscroll** is contained (`overscroll-behavior: contain`): the graph behind never scrolls along; the rubber band is the platform's.
- Follows "Show scroll bars": with "Always", keep the bar shown (Flutter: `NSScroller.preferredScrollerStyle`).
- Keyboard · VoiceOver · Reduce motion: the viewport is one Tab stop and draws the focus ring **inside** (its container clips) · ↑ ↓ ← → 40px · Page Up / Page Down and Space / ⇧Space one page less 40 · Home / End · a region labelled by `label`; the bars are decoration (VoiceOver scrolls with its own commands) · the thumb's widening is movement (`--dur-nudge` → 0), its fades stay.
