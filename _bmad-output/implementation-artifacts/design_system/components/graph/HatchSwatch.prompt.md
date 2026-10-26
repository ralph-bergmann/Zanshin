The swatch for **immutable** — the card's hatch in miniature. Put it before the word wherever immutable is named; on the graph itself the card's hatch says it (`ChangeCard immutable`).

~~~jsx
<Flag icon={<HatchSwatch/>} title="Immutable · below trunk() · main">Immutable</Flag>
<Menu items={[…, "sep", { note: "Immutable · below trunk() · main", icon: <HatchSwatch/> }, { id: "imm", label: "Immutable commits…", icon: "settings" }]}/>
<PeekCard immutable immutableWhy="below trunk() · main" … />   {/* the eyebrow carries the swatch */}
~~~

- 12 × 12 (`--icon-sm`): radius `--radius-kbd` (3), 1px `--border-strong`, `--card-solid`, a 135° hatch 1px every 3px in `--hatch-mark` (30% of `--text`). The card's own hatch: 1px every 6px in `--hatch` (7%).
- **Immutable has no colour and no ◆** — the hatch is the marker, the swatch names it. Gold stays with @, moon with the selection. (`◆` is retired: only people who know jj read it.)
- Keyboard · VoiceOver · Reduce motion: not focusable · decoration (`aria-hidden`) beside its word; alone, give it a `title` and it becomes an image with that label · nothing moves.
