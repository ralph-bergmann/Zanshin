Text button for commands; use `primary` for exactly one action per view (gold), the quiet default for the rest.

~~~jsx
<Button variant="primary" size="lg" icon="plus" title="jj new — start a new change on top of @">New change</Button>
<Button icon="describe">Describe…</Button>
<Button variant="danger" icon="abandon">Abandon</Button>
~~~

- Labels are verbs in sentence case; put the jj command in `title` (tooltip), not in the label.
- Destructive actions are `danger` and sit last (inspector: pushed right).
