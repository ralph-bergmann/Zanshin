One parent → child line of the change graph (inside an `<svg>`); `GraphEnd` marks where the revset cuts off older history; `GraphPorts` holds the router's port and line rules.

~~~jsx
const W = 240, [e] = GraphPorts.exits(1, W);          // a fork beside the straight line: 24px right of the centre
<svg width={700} height={360}>
  <GraphEdge from={[144 + e, 246]} to={[440, 198]} bend={222}/>   {/* fork: own exit, turns just above the parent */}
  <GraphEdge from={[144, 136]} to={[144, 84]} kind="wc"/>          {/* straight: centre exit, centre entry */}
  <GraphEdge from={[440, 330]} to={[440, 246]} gap/>               {/* hidden history: dashed + break mark */}
  <GraphEdge points={[[300, 246], [300, 222], [416, 222], [416, 104], [530, 104], [530, 84]]} cuts={[GraphPorts.bridge(416, 160, "v")]}/>
  <GraphEnd x={144} y={308}/>
</svg>
~~~

- **One line per parent → child pair.** Every line has its own exit on the parent's top edge and its own entry on the child's bottom edge. Top and bottom follow one rule set: a lone line sits at the centre; of several, the straight one (first parent, same lane) does and the rest sit beside it — the farther the turn, the farther out; with none straight the centre stays free. Dashed lines through the same hidden parent share one entry and one break mark.
- **The fan depends on the card width** (`GraphPorts.exits` / `entries`, the same at both edges): 24px from the centre, then 16px apart while they fit within 18px of the card edge; with less width they squeeze down to 8px; beyond that the outermost lines share one port and split beside the card. A merge-up climbs its parent's own lane past the entries of the cards above, so its exit never takes the centre and sits `MERGE_UP_SHIFT` (4px) outside its slot.
- **Runs:** forks turn just above the parent, merges just below the child; horizontal runs stack in tracks 3.5–6px apart (`trackSpacing`) and nest instead of crossing. A merge whose parent lane is taken climbs the gutter between columns; in the Free layout a run that would pass behind a card detours through a gutter too (`points`).
- **Bridges:** where two lines cross, the horizontal one breaks (12 × 10, `cuts`) and keeps ≥ 12px of visible line to the next bend or card; if it has no room there, the vertical one breaks instead (`bridge(x, y, "v")`).
- **Gap marker:** `gap` turns the line dashed (3 5) with the break mark. It never sits right at a card — the first stretch with room, scanning from the child, 8px off the card edge and 12px off a bend; on a hidden merge's shared stem pass `gapAt` so the mark keeps 12px of line on both sides; with no room anywhere it takes the middle of the longest stretch. No counts on the line; counts live in the hover callout.
- Elbows are rounded at 10px. `kind="wc"`: the path from @ down to trunk — saffron, 2.25px, soft glow; only @ gets saffron. Hover a card → its lines go `kind="hover"`; while dragging, unrelated lines `dim`.
