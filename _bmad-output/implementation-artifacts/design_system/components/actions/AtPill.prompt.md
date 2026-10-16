Floating pill that scrolls back to the working copy; render it only while @ is out of view, bottom-centre over the visible part of the graph.

~~~jsx
{wcOffscreen && <AtPill direction="up" onClick={scrollToWc} />}
~~~

- 36px glass pill, the @ chrome edge (`--at-chrome-edge`), the arrow pointing toward @.
- Never a permanent button. In: fade + 10px rise (`--dur-slide`, glide); out: fade (`--dur-exit`). When the visible area changes (inspector, panel) it re-centres on `--dur-move`; when @ moves to the other side its arrow turns on `--dur-toggle`. It steps aside while the graph scrolls (calm scrolling) and while a toast shows.
- Keyboard · VoiceOver · Reduce motion: a Tab stop while shown (out of the order when hidden); ↩ / Space scroll to @ and select it · button "Working copy, below" · it simply appears and points — rise, re-centring and the turn are movement (→ 0), the fade stays.
