One row in a SettingsGroup: what it is, what it writes, and the control.

~~~jsx
<SettingsRow label="Hide controls" hint="Toolbars and panels step aside while you scroll the graph. The minimap stays.">
  <Switch label="Hide controls while scrolling" checked={on} onChange={setOn}/>
</SettingsRow>
<SettingsRow label="Immutable heads" hint="Changes at or below these can’t be rewritten." configKey={'revset-aliases."immutable_heads()"'} stack>
  <TextField mono defaultValue="builtin_immutable_heads()"/>
</SettingsRow>
~~~

- `configKey` shows the exact jj key in mono under the label — Zanshin never hides what it writes.
- Controls: `Switch`, `Segmented variant="inset"`, `Select`, `TextField` (240px; full width when `stack`).
