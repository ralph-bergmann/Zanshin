Settings › Project › Immutable commits — `revset-aliases."immutable_heads()"` without writing a revset. A `SettingsPage`, opened from History's navigation row or from the card menu of an immutable change (Immutable commits…).

~~~jsx
const [cfg, setCfg] = React.useState(ImmutablePage.defaults);
<SettingsRow label="Immutable commits" hint={ImmutablePage.summary(cfg)} configKey={'revset-aliases."immutable_heads()"'} onOpen={() => setPage("immutable")}>
  <span className="zs-setrow-count"><HatchSwatch/>{count}</span>
</SettingsRow>
<ImmutablePage config={cfg} onChange={setCfg} project="MyApp" onBack={() => setPage(null)} trunkName="main"
  tags={["v1.0.0", "v1.4.2"]} remoteBookmarks={["release/1.5.x@origin"]} bookmarks={["develop", "release/1.1.0-rc1"]}
  count={14} heads={["main", "v1.0.0", "v1.4.2"]} />
~~~

- **Built in** (`builtin_immutable_heads()` beside the heading): Trunk · Tags · Remote bookmarks you don't track · Remote tags you don't track — switch rows whose hints name what matches here. All four on = jj's default (v0.46: `trunk() | tags() | untracked_remote_bookmarks() | untracked_remote_tags()`).
- **Also immutable:** Other people's changes (`trunk().. & ~mine()`, jj's own example; the hint warns that what's below them is locked too) · Bookmarks (filter chips, mono, + a Bookmark… add chip that opens a menu of the rest) · Custom revset (mono field, joined with `|`; terms the preview can't evaluate are listed: "Not previewed here: …").
- **Result:** the diff-block well (`--code-bg`, `--fl-border`, radius 12) with the TOML exactly as written (`ImmutablePage.toml`; the key `"immutable_heads()"` in `--text`, the rest `--text-muted`), then `HatchSwatch` + "**N** changes are immutable" and the heads in mono. Below it: "root() is always immutable. To rewrite one anyway, jj needs `--ignore-immutable`." and **Reset to jj's default** while the set differs.
- Everything applies at once (as all of Settings): the app evaluates heads + ancestors and the cards change live. The trunk alias itself is History › Trunk; Reset leaves it alone.
- Copy: "jj won't rewrite these changes or anything below them: no edit, describe, squash, rebase or abandon. New change on top and Revert still work. In the graph they're hatched."
- Keyboard · VoiceOver · Reduce motion: as SettingsPage (⌘[ back) · each switch row is one control with its label and hint · chips: Tab to a chip's ✕ ("Remove develop"), the add chip opens its menu (↑↓ ↩ Esc) · the well is plain text, selectable · nothing animates but the switches.
