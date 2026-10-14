Icon-only button for island toolbars, the rail and panel close buttons.

~~~jsx
<IconButton icon="fetch" label="Fetch — jj git fetch" />
<IconButton icon="branch" label="Bookmarks" size="lg" active />
<IconButton icon="close" label="Close" size="sm" />
~~~

- Always pass `label`; tooltips name the action and its jj command ("Push — jj git push").
