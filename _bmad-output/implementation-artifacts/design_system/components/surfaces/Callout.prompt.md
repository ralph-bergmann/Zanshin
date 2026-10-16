Callout that previews a rail panel on hover (bookmarks, reviews, undo timeline); click the rail button to pin the real panel.

~~~jsx
<Callout icon="branch" title="Bookmarks" count={0}>
  <CalloutText>No bookmarks yet. Create one with <code>jj bookmark create &lt;name&gt;</code>.</CalloutText>
</Callout>
~~~

- The one menu material (13px, `--fl-sheen` over `--fl-bg-solid`, `--shadow-menu`), 290px, the arrow pointing at its button. Opens after `--delay-callout` (90ms), stays `--delay-callout-out` (200ms) after the pointer leaves — long enough to move into it.
- Empty states are one quiet sentence, often with the real command that fixes them.
- Keyboard · VoiceOver · Reduce motion: hover-only preview — the keyboard path is the rail button itself (↩ pins the panel) · not announced; the pinned panel is · fades in (its 4px slide × `--motion`).
