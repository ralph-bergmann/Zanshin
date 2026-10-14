Native dropdown for settings with a handful of fixed choices (remotes, trunk bookmark).

~~~jsx
<SettingsRow label="Fetch from" configKey="git.fetch">
  <Select label="Fetch from" value={fetch} onChange={setFetch} options={["origin", "upstream"]}/>
</SettingsRow>
~~~

- Same well, border and moon focus ring as `TextField`; 30px tall, 12.5px, min-width 170px.
- 2–3 short options → prefer `Segmented`; long or open-ended lists → `Select`.
