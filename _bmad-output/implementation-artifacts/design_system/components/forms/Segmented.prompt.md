Segmented control for 2–4 mutually exclusive options (View options › Layout, Settings scope tabs, theme).

~~~jsx
<Segmented label="Layout" value={layout} onChange={setLayout} options={[{ value: "free", label: "Free" }, { value: "compact", label: "Compact" }]} />
<Segmented variant="tabs" label="Scope" value={tab} onChange={setTab}
  options={[{ value: "general", label: "General", icon: "settings" }, { value: "project", label: "Project", disabled: !repo, title: "Open a project first" }]} />
~~~

- The thumb slides (`--dur-toggle` 180ms, `--ease-glide`); reduce motion: it jumps. Hover brightens the label, pressed adds `--fl-hover` under the segment.
- A disabled segment stays visible at .4 and keeps its tooltip (aria-disabled) — say why it's unavailable.
- Keyboard: one tab stop; ←/→ choose (skip disabled). VoiceOver: radio group (tabs: tab list).
