A page inside a Settings tab — for a setting too big for one row. A **navigation row** leads there; the page's back button leads back.

~~~jsx
<SettingsGroup title="History">
  <SettingsRow label="Trunk" configKey={'revset-aliases."trunk()"'}><Select … /></SettingsRow>
  <SettingsRow label="Immutable commits" hint={ImmutablePage.summary(cfg)} configKey={'revset-aliases."immutable_heads()"'} onOpen={() => setPage("immutable")}>
    <span className="zs-setrow-count" title="2 immutable changes"><HatchSwatch/>2</span>
  </SettingsRow>
</SettingsGroup>

{page === "immutable" && <SettingsPage back="MyApp" onBack={() => setPage(null)} title="Immutable commits" intro="jj won’t rewrite these changes …">…groups…</SettingsPage>}
~~~

- **The navigation row** (`SettingsRow onOpen`): label, the current setting in words (hint), the config key, then a value (a count) and ›. The whole row is the button: hover `--fl-on`, pressed `--fl-press`, focus inside.
- **The page** replaces the tab's groups in the window body — the tabs, the scope line and the footer stay; the window's title (Window menu, Mission Control) becomes the page's name. Back: "‹ MyApp" (26px, radius 7, `--text-muted`; hover `--fl-hover`). Title 17/600, −0.01em; one sentence in 12.5 `--text-muted`, at most 500 wide. Then groups as on any tab; changes apply at once.
- A page belongs to its tab: General hides it, Project shows it again; ⌘, brings the window forward as it is; closing the window leaves the page. A card-menu row can open Settings on the page directly (the card menu's Immutable commits…).
- Keyboard · VoiceOver · Reduce motion: the navigation row is a button (↩ / Space open it); on the page Tab starts at the back button, ⌘[ goes back · VoiceOver reads the back button as "Back to MyApp" and the title as a heading · the page swaps in place, no slide.
