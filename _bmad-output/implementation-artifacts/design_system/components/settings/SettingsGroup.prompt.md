Caps-headed box of setting rows — the building block of the Settings window (General and Project tabs).

~~~jsx
<SettingsGroup title="Remotes">
  <SettingsRow label="Fetch from" configKey="git.fetch"><Select value="origin" options={["origin", "upstream"]}/></SettingsRow>
  <SettingsRow label="Fetch automatically"><Segmented variant="inset" value="15" options={[{ value: "off", label: "Off" }, { value: "5", label: "5 min" }, { value: "15", label: "15 min" }]}/></SettingsRow>
</SettingsGroup>
~~~

- Box = `--fl-hover` fill, 12px radius, rows divided by `--fl-border` hairlines; groups 18px apart.
- Headings are short nouns ("Appearance", "While you scroll", "Identity"), rendered in caps by CSS — write them in sentence case.
