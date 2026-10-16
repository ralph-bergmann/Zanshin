Icon-only button for island toolbars, the rail and panel close buttons.

~~~jsx
<IconButton icon="fetch" label="Fetch — jj git fetch" />
<IconButton icon="branch" label="Bookmarks" size="lg" active />
<IconButton icon="close" label="Close" size="sm" />
~~~

- Always pass `label`; tooltips name the action and its jj command ("Push — jj git push").
- Keyboard · VoiceOver · Reduce motion: a Tab stop (the rail: its focus ring inside); Space / ↩ · button with `label`, toggles `aria-pressed`, the badge count in the label ("Fetch, 3 new") · colour only.
