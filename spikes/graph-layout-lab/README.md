# Graph layout lab

A browser page for trying layout rules fast. It exists because the product engine grew rule by rule
and still shows outliers, and every check of a change needed the app and the quality gate.

Approved by Ralph on 2026-11-09.

## Intent

- See the effect of a rule change in seconds, on real repositories.
- Start again from a simple algorithm and add one rule at a time. Ralph looks at each step.
- Find rules that fix what the engine gets wrong today:
  - the main branch drifts to the right and does not come back;
  - a card sits far from the lines it connects to;
  - a line runs a long way close to cards instead of turning before a card.

## Not part of the lab

- No change to the app or to `packages/zanshin_core`. No goldens, no quality gate.
- Moving an approved algorithm into the engine is a later step, with the gate.
- No performance work. The lab code is plain and readable.

## Approaches

| Approach | Trade-off |
|---|---|
| **Dart behind a local process (chosen)** | A reload takes 1–2 s. Approved rules move into the engine without a rewrite. The page can show today's engine next to the lab. |
| JavaScript in the page | A reload is instant. Everything must be ported to Dart at the end. |

Ralph left the choice to Claude.

## How it works

- `bin/lab_server.dart` serves the page and answers `/api/layout`. For each request it starts
  `bin/lab_layout.dart` in a new process, so a code change needs no restart.
- `bin/lab_layout.dart` reads one data set and writes one JSON document: cards (position, text) and
  lines (points). The page only draws what it gets.
- Two engines write the same JSON:
  - **Lab**: rows and stacks from the product engine, columns and lines from `lib/`.
  - **App today**: the product engine and its router, unchanged.

## The page

- Controls: repository, Lab or App today, Free or Compact, stacks, one switch per rule, metrics.
- The graph: cards, lines, day marks. It scrolls and zooms.
- A click on a card or a line copies its id and a link to that place.
- Metrics: columns, crossings (and how many between two lines of one card), lines on top of each
  other, bends, lines behind a card, cards with a free column nearer to their lines.

## Data

The lab never runs jj in a real repository. `tools/replica.sh` reads `git log`, builds a copy of the
commit graph under `data/` and dumps the layout input from the copy. `data/` is ignored by git.

- With `--subjects`: the copy keeps each commit's subject and author. For own and public repositories.
- Without: empty commits whose subject is the short hash. For client repositories.

## Run

```bash
dart run spikes/graph-layout-lab/bin/lab_server.dart
```

Then open <http://127.0.0.1:8768/>. Reload the page after a change to the lab's code. In Claude Code
the launch entry `graph-layout-lab` starts the same server.

Make a data set (needs the dumper of the A/B spike, built once with
`cargo build --release --manifest-path spikes/graph-layout-ab/rust-inputs/Cargo.toml`):

```bash
spikes/graph-layout-lab/tools/replica.sh <git repository> <name> [--subjects]
```

Check the rules on every data set (seconds, no gate):

```bash
dart --packages=.dart_tool/package_config.json run spikes/graph-layout-lab/bin/lab_check.dart spikes/graph-layout-lab/data
```

It also checks that the product's columns equal `lib/columns.dart`; a goldens directory as a second argument runs that check on every golden input.

Print the metrics of every data set, to compare before and after a rule change:

```bash
dart --packages=.dart_tool/package_config.json run spikes/graph-layout-lab/bin/lab_metrics.dart spikes/graph-layout-lab/data
```

## Step 1

Code: `lib/columns.dart` (rules 1–3) and `lib/lines.dart` (rule 4).

1. The main branch is always in column 0, and nothing else is. The main branch is the first-parent
   chain through `trunk()`; above the trunk's head it goes on with the branch that continues it.
2. A branch (a first-parent chain) gets one column for its whole life.
3. It takes the free column nearest to the column it docks to. A column is taken only where cards
   are, not up to the merge.
4. A line runs in its branch's column. Where a card is in the way, it turns into the gutter next to
   the column before the card.

Known limits of step 1, measured on `dart-intellij-third-party` (4,672 commits, Free, stacks):

| | Lab, step 1 | App today |
|---|---|---|
| columns | 4 | 11 |
| crossings | 354 | 127 |
| bends | 1,746 | 1,366 |
| lines behind a card | 4 | 0 |

- Nothing avoids crossings yet, and every branch is right of the main branch.
- A horizontal run is not checked for cards. The page draws such a line red.
- All lines of a card share its centre, so lines to one card run on top of each other near it.

## Step 2: short branches first, near the main branch

Asked for by Ralph on 2026-11-10, after a look at git-graph: there a short branch sits inside and a
long one runs around it. Three switches, all on by default:

- **Short branches first** (`short-first`): branches are placed by length, the shortest first, each
  in the free column nearest to the main branch. Without it step 1's order applies: oldest first,
  nearest to the column the branch docks to.
- **Column taken up to the merge** (`reserve-to-merge`): a branch takes its column from its fork up
  to its last merge, lines included. Its length is measured over the same rows. Without it a column
  is taken only where cards are (step 1).
- **Lines dodge cards** (`dodge`): step 1's rule 4.

What follows from the first two: a branch whose rows lie inside another's sits nearer to the main
branch, and the two do not cross. `bin/lab_check.dart` checks this.

Measured with stacks, crossings / bends / columns:

| | App today | Step 1 | Step 2 |
|---|---|---|---|
| dart-intellij, Free | 127 / 1,366 / 11 | 354 / 1,746 / 4 | 104 / 1,338 / 11 |
| dart-intellij, Compact | 96 / 1,344 / 11 | 342 / 1,446 / 11 | 99 / 1,338 / 11 |
| jj, Free | 317 / 556 / 14 | 464 / 712 / 7 | 7 / 544 / 11 |
| jj, Compact | 120 / 544 / 14 | 123 / 546 / 12 | 2 / 544 / 12 |
| TWMS, Free | 117 / 700 / 11 | 512 / 836 / 9 | 194 / 692 / 11 |
| TWMS, Compact | 85 / 702 / 11 | 377 / 736 / 8 | 184 / 692 / 10 |

Open in step 2:

- In Free, 3 to 8 lines per repository still pass behind a card with a horizontal run.
- On TWMS the app has fewer crossings. There its main branch sits in the middle, with branches on
  both sides.

## Step 3: a horizontal run looks for a free level

Asked for by Ralph on 2026-11-10: he liked step 2 except for lines behind cards and one needless
jog. One switch, on by default (`free-level`), code in `lib/lines.dart`:

- A fork line's horizontal run sits right above the parent, a merge line's right below the child.
  Where a card stands at that level in a column the run crosses, the run moves to the nearest free
  level, at least 8 px from every card. A fork run may climb the parent's column up to that
  column's next card; a merge run may sink down the child's column to that column's next card.
- A merge line whose parent's column is taken right above the parent turns at such a level too, if
  the child's column is free from there up to the child. Before, it always went through the gutter.
- Without a free level the line keeps step 1's shape and may pass behind a card.

Measured in Free with stacks, step 2 → step 3:

| | lines behind a card | crossings | bends |
|---|---|---|---|
| dart-intellij | 8 → 0 | 104 → 114 | 1,338 → 1,334 |
| jj | 3 → 0 | 7 → 9 | 544 → 544 |
| TWMS | 8 → 0 | 194 → 205 | 692 → 690 |

A run that leaves a card now crosses a line instead. Compact does not change, apart from two
bends less on TWMS.

Open in step 3: a merge run that sinks down the child's column lies on that column's own line for
a stretch, so the two look like one line there.

## Step 4: horizontal runs share the free room evenly

Asked for by Ralph on 2026-11-10: a run that had moved passed 8 px from a card although there was
more room. One switch, on by default (`spread`; it needs `free-level`), code in `lib/lines.dart`:

- Every run with two bends has a band: from the nearest card above it to the nearest card below
  it, among the columns it crosses and its own two cards.
- The runs that pass through a band side by side share it evenly, in the order they had. They sit
  at most 19 px apart (0.4 of the row gap), and a run alone keeps that distance from the card on
  its own side: a merge run from the top, a fork run from the bottom. So in a wide band nothing
  changes, and in a narrow one the room is split into equal parts.
- The runs of one card on one level stay one bus.

Crossings, bends and lines behind cards do not change on dart-intellij and jj. On TWMS in Compact
the crossings rise from 184 to 192: two runs that lay on top of each other are now two lines.

## Step 5: ports in a fan, every line on its own track

Asked for by Ralph on 2026-11-10: "as we already have it". One switch, on by default (`ports`), code
in `lib/lines.dart`. The rules are the app's (docs/graph-layout.md §14.3, Ports), in a plain form:

- Per card edge one line sits at the centre. Of several, the line that stays straight longest
  does, if it runs at least a row gap (48 px) before it turns. With no such line the centre stays
  free.
- The other lines fan out to the side they turn to, 24 px from the centre, then 16 px apart (less
  with more than five on a side, never under 8 px). The line that turns nearest to the card sits
  outermost, so the lines of one card edge do not cross.
- The lines of one card to one side that shared a level each get a track of their own, 6 px apart
  (less in a narrow band). The line to the nearest card turns furthest from the card. Step 4's
  even sharing places the group as a whole.

What follows: two lines into one card never lie on top of each other. A merge run that sinks down
the child's column now climbs next to that column's own line.

The metrics do not change (one crossing more on dart-intellij in Free and on TWMS in Compact).
`bin/lab_check.dart` checks that every line ends on its card's edge, at least 18 px from the
corners, and that no two lines of a card edge share a port.

Left out from the app's rule: the tie-break between two vertical lines of different cards in one
column, and shared entries of indirect lines.

## Step 6: tracks in the order in which lines do not cross

Asked for by Ralph on 2026-11-10: two lines left one card and crossed, because a merge run sat
near its child (above) and a fork run near its parent (below), whatever their targets. No new
switch: `spread` now does this (code in `lib/lines.dart`), and it replaces how steps 4 and 5
ordered runs.

- A run's line goes down at its parent's end and up at its child's end. So run A must lie above
  run B if A spans B's parent end, or B spans A's child end; otherwise the two cross. This is the
  app's rule for tracks (docs/graph-layout.md §14.3, "Runs and tracks").
- The runs that pass side by side through bands that overlap form a cluster. A cluster is ordered
  by that rule; where the rule decides nothing, the run that wants to sit higher comes first.
- Every run sits where it wants to (19 px from the card on its side, or the middle of a narrow
  band) unless the order pushes it. Runs that meet keep their even share of the band apart, at
  most 19 px; two lines that leave one card, or reach one card, on the same side keep 6 px.
- A run never leaves its band, so no push can send a line behind a card.

Measured with stacks, crossings before → after:

| | Free | Compact |
|---|---|---|
| dart-intellij | 115 → 88 | 99 → 73 |
| jj | 9 → 9 | 2 → 2 |
| TWMS | 205 → 169 | 193 → 135 |

`bin/lab_check.dart` checks that two lines which both turn right at one card edge do not cross.
Two lines of one card can still cross when one of them turns far away, at its other card: cards
lie in between, and a swap of tracks cannot help.

## Step 7: a merge line bends at its parent; no lines on top of each other

Asked for by Ralph on 2026-11-10: two lines of one card still crossed where one bent at the card
and the other far away, at its child. His idea: the order of the cards is the order in which the
lines leave. Two switches, on by default, code in `lib/lines.dart`:

- **A merge line bends at its parent** (`bend-at-parent`; it needs `free-level`): where the
  parent's branch goes on (a first-parent child sits in the parent's column), the merge line bends
  at the parent, like a fork line, and climbs the child's column. It does so only if the child's
  column is free from the child down to the parent. Else it keeps its shape: it climbs the parent's
  column and bends at the child.
- **No lines on top of each other** (`no-overlap`; it needs `spread`): in the room between two
  cards of one column, a run that enters the upper card lies above a run that leaves the lower
  card. Before, step 6's order could push the lower card's run up to the upper card to save a
  crossing. The two lines then shared a stretch of the column, and the metrics did not count that.
  Now each run bends at its own card and the two lines cross once, away from the cards.

What follows from the first switch: every line of such a card's top edge bends at the card. Step
6's order then gives the line to the farthest card the lowest track and the outermost port. So the
order of the cards is the order of the lines, as Ralph proposed.

Tried and dropped, measured on TWMS in Free (crossings / of them between two lines of one card):

| Variant | Result |
|---|---|
| step 6 | 169 / 6 |
| ports in the order of the cards, bends unchanged | 189 / 25 |
| `bend-at-parent` | 157 / 1 |
| `bend-at-parent` and ports in the order of the cards | 160 / 4 |
| every merge line bends at its parent where the child's column is free | 155 / 1, and more lines on top of each other (dart-intellij 23 → 27) |

The order of the ports alone moves the crossing from the child to the parent. The bend has to
move; then step 5's ports follow.

Two new metrics: `siblings` (crossings of two lines that leave one card or reach one card) and
`overlaps` (two runs of different lines on top of each other). `bin/lab_metrics.dart` prints all
metrics for every data set.

Measured with stacks, crossings / of one card / overlaps:

| | Step 6 | + `bend-at-parent` | + `no-overlap` |
|---|---|---|---|
| dart-intellij, Free | 88 / 0 / 23 | 88 / 0 / 23 | 108 / 0 / 3 |
| dart-intellij, Compact | 73 / 0 / 50 | 73 / 0 / 50 | 95 / 0 / 28 |
| jj, Free | 9 / 0 / 0 | 9 / 0 / 0 | 9 / 0 / 0 |
| jj, Compact | 2 / 0 / 2 | 2 / 0 / 2 | 2 / 0 / 2 |
| TWMS, Free | 169 / 6 / 16 | 157 / 1 / 15 | 171 / 1 / 1 |
| TWMS, Compact | 135 / 0 / 30 | 134 / 0 / 30 | 157 / 0 / 7 |

With `no-overlap` crossings plus overlaps stay the same: every shared stretch was a crossing the
metric did not count. So step 6's crossings were too low by that much.

Open in step 7:

- One crossing of two lines of one card is left on TWMS: the child's column is taken, so the merge
  line cannot bend at its parent.
- Overlaps left: two lines that cross whichever run lies above, and share a port's x in one of the
  two columns; and in Compact a card with five or more lines to one side, whose runs lie on one
  level (10 of the 28 on dart-intellij).

## Step 8: the same columns in Free and Compact

Ralph on 2026-11-10, after step 7: "with all switches on we can take it over". The engine gives
every card the same column in both modes (docs/graph-layout.md §13, joint columns); the lab chose
its columns per mode, so that rule would have been lost. One switch, on by default
(`same-columns`), code in `lib/columns.dart`:

- A column is free for a branch only if it is free in Compact's rows and in Free's.
- Free's rows decide which branch is short and which is the main branch.

Measured with stacks, crossings plus overlaps / columns:

| | Columns per mode | Same, Compact's rows decide | Same, Free's rows decide |
|---|---|---|---|
| dart-intellij, Free | 111 / 11 | 112 / 11 | 111 / 11 |
| dart-intellij, Compact | 123 / 11 | 123 / 11 | 122 / 11 |
| jj, Free | 9 / 11 | 99 / 13 | 18 / 13 |
| jj, Compact | 4 / 12 | 7 / 13 | 8 / 13 |
| TWMS, Free | 172 / 11 | 264 / 11 | 169 / 11 |
| TWMS, Compact | 164 / 10 | 159 / 11 | 159 / 11 |

A branch that is short in Compact can be long in Free, where the rows follow the time. So Free's
rows decide. `bin/lab_check.dart` checks that both modes get the same columns.

**The price: gaps (Ralph on 2026-11-10, jj in Free at `mnxzqvtl`, `mwlqywqy`, `kuyukkqn`).** A
branch sits further right than its mode needs, because the columns to its left are taken in the
other mode. At `mnxzqvtl` seven branches fork; in Free they sit in columns 1, 4, 5, 8, 9, 11, 12.
Columns 2, 3, 6 and 7 are taken in Compact, by branches that lie further down in Free.

Measured without stacks, all other switches on (Free / Compact):

| | Same columns | Columns per mode |
|---|---|---|
| jj: columns | 13 / 13 | 11 / 12 |
| jj: branches with a free column to their left, of 262 | 21 / 28 | 0 / 0 |
| jj: crossings plus overlaps | 21 / 45 | 32 / 12 |
| jj: cards that change their column between the modes, of 15988 | 0 | 3307 |
| TWMS: columns | 11 / 11 | 11 / 10 |
| TWMS: branches with a free column to their left, of 153 | 7 / 17 | 1 / 2 |
| TWMS: crossings plus overlaps | 162 / 169 | 166 / 162 |
| TWMS: cards that change their column, of 1622 | 0 | 480 |
| dart-intellij: branches with a free column to their left, of 330 | 1 / 20 | 0 / 0 |
| dart-intellij: crossings plus overlaps | 112 / 123 | 112 / 123 |
| dart-intellij: cards that change their column, of 4672 | 0 | 41 |

With columns per mode, jj in Free has ten overlaps at one card (`pznposwy`): the top card of a
long branch lands next to its fan of seven lines, and five of them share a level.

Tried in a script, not built: the same columns, then each mode moves every branch left as far as
the branches beside it allow, in the same left-to-right order. jj in Free: 21 → 2 branches with a
gap, but 3122 cards still change their column. That keeps little of what same columns are for.

Ralph on 2026-11-10: columns per mode (step 13).

## Step 9: which branch sits inside when two overlap in part

Ralph on 2026-11-10, on TWMS at `f993012`: that branch sat in column 1, and two branches that
merge earlier ran around it. He expected it outside: it skips three commits of the main branch.

The lab followed its rule. "Short first" measures a branch on the page, from its fork to its last
merge; in Free that is time. The branch of `f993012` was the shortest, 196 rows; the other two
have 228 and 244, because they fork further down.

Two branches side by side lie one inside the other, or they overlap in part:

- Inside: every rule here puts the inner branch nearer to the main branch, and no line crosses.
- In part: one line crosses, whichever branch sits inside. The rules differ only in the picture.

Two switches, code in `lib/columns.dart`; both need `short-first`:

- **The branch that ends first sits nearer to the main branch** (`ends-first`, on): it merges
  first, or its last card comes first. Of two that end on one row, the shorter. So a merge line
  reaches the main branch below the merge lines of the branches further out.
- **The branch that skips fewer commits sits nearer** (`fewest-skipped`, off): Ralph's count, placed
  before the rule above. A branch skips the cards of the branch it forks from that lie between its
  fork and its end.

At `f993012`: "ends first" puts it in column 3, as Ralph drew it. "Fewest skipped" alone does not:
it and one of the other two both skip three commits, so a second rule has to decide.

Measured with the same columns in both modes, crossings plus overlaps:

| | Shortest first | Ends first | Fewest skipped, then ends first |
|---|---|---|---|
| dart-intellij, Free | 111 | 112 | 116 |
| dart-intellij, Compact | 122 | 123 | 131 |
| jj, Free | 18 | 21 | 20 |
| jj, Compact | 8 | 10 | 11 |
| TWMS, Free | 169 | 160 | 170 |
| TWMS, Compact | 159 | 154 | 160 |
| dart-intellij, Free, no stacks | 111 | 112 | 115 |
| dart-intellij, Compact, no stacks | 122 | 123 | 131 |
| jj, Free, no stacks | 18 | 21 | 20 |
| jj, Compact, no stacks | 26 | 45 | 54 |
| TWMS, Free, no stacks | 172 | 166 | 175 |
| TWMS, Compact, no stacks | 192 | 186 | 190 |
| all | 1,228 | 1,233 | 1,293 |

"Fewest skipped" compares two branches well only if they fork from the same branch, and its
counts are often equal. Also tried: the length in Compact's rows for both modes. Free gets much
worse with it (TWMS 169 → 245, jj 18 → 32).

`bin/lab_metrics.dart` now measures without stacks too.

## Step 10: a run may come within 8 px of its own card

Asked for by Ralph on 2026-11-10: without stacks one line on TWMS in Free passed behind a card
(`4b195c2` → `b490088`, behind `7fb0a9d`). The only free level lay 13 px above the line's parent,
and a run had to keep 19 px from its own two cards. No switch: `free-level` now does this (code
in `lib/lines.dart`, `seek`).

- A run still sits 19 px from its own card where that level is free.
- Where it is not, the run takes the nearest free level in its usual direction, else in the other
  one. It keeps 8 px from every card, its own two included.

Only that one line changes on the three data sets. `bin/lab_check.dart` now also runs without
stacks and fails when a line passes behind a card, with a vertical or a horizontal run.

## Step 11: side branches next to their branch; a merge line may climb next to its child's column

Ralph on 2026-11-10, two places on TWMS without stacks:

1. At `b70eb2d`: a branch of two cards that forks from a branch in column 5 and merges back into
   it sat in column 1. With `short-first` every branch docked to the main branch.
2. At `4ef92fa`: the lines did not leave in the order of their children's columns. The line to
   the nearest column left third. Two merge lines could not bend at the card, because their
   child's column is taken below the child. They climbed the main branch's column, and the line
   that stays straight longest has to sit innermost: else it crosses the lines that bend at the
   card.

Two switches, on by default:

- **A side branch sits next to its branch** (`dock-to-parent`; it needs `short-first`; code in
  `lib/columns.dart`): a branch that forks from another branch than the main one, and merges into
  no third branch, takes the free column nearest to the branch it forks from (the left one on a
  tie). Such branches are placed after the branch they fork from. A branch that also merges
  somewhere else, into the main branch for one, docks to the main branch as before.
- **A merge line takes the way with fewer crossings** (`fewer-crossings`; it needs
  `bend-at-parent`; code in `lib/lines.dart`): where the child's column is taken, the line can
  bend at its parent all the same, run to the gutter next to the child's column and climb there.
  That costs two bends. It does so only if it then crosses fewer lines, and only if it climbs
  past at least one row of cards. The crossings are counted on the shapes before tracks and ports.

At `4ef92fa` the four lines now leave in the order of their columns: 1, 3, 5, 8.

Measured (dart-intellij and jj do not change, apart from two bends):

| TWMS | Before | + `dock-to-parent` | + `fewer-crossings` |
|---|---|---|---|
| Free: crossings / of one card | 160 / 1 | 163 / 1 | 162 / 0 |
| Compact | 154 / 0 | 156 / 0 | 156 / 0 |
| Free, no stacks | 166 / 4 | 169 / 4 | 162 / 0 |
| Compact, no stacks (plus overlaps) | 186 / 0 | 187 / 0 | 172 / 0 |
| columns between parent and child, all lines | 870 | 853 | 853 |
| bends, Free | 690 | 690 | 704 |

Tried and dropped:

- Every side branch docks to the branch it forks from, also one that merges into the main branch:
  TWMS in Free 160 → 174 crossings.
- Every such merge line takes the gutter: dart-intellij in Compact 111 → 131 crossings, and a
  zigzag between two neighbouring rows.

A new metric, `sideways`: the columns between parent and child, summed over all lines.

## Step 12: the lines of a card turn in the order of their columns, always

Ralph on 2026-11-10: lines that leave or reach a card in another order than their columns look
unsorted. The order should hold always, not only where it saves crossings.

After step 11 it held nearly everywhere. Counted per card edge with two or more lines that turn
there, over the three repos, both modes, with and without stacks: four card edges were out of
order.

- dart-intellij in Compact at `regexp: fix tests`, jj in Compact at `wasm: Allow jj-lib
  compilation to wasip2`: several lines turn on one level, because the row gap has no room for a
  track each. Their ports followed the lines' numbers.
- TWMS in Compact without stacks at `554936a` and `b6e4ab5`: a merge line climbed the main
  branch's column, and its detour (step 11) saved no crossing.

One switch, on by default: **the lines of a card turn in the order of their columns, always**
(`column-order`; it needs `fewer-crossings`; code in `lib/lines.dart`).

- A merge line takes its detour too wherever a line of its card to the same side goes to a nearer
  column but turns nearer to the card, whatever the detour crosses.
- Of the lines that turn on one level, the one to the nearer column gets the inner port.

Measured: no card edge is out of order, on any repo, in either mode, with or without stacks. Only
TWMS in Compact without stacks changes: 171 → 169 crossings, 1 → 0 overlaps, 702 → 704 bends.
`lab_check` checks the order.

Limits:

- The order covers the lines that turn at the card. The line at the centre port runs straight on
  and is no part of it. At TWMS `dfab6b3` the branch's first line climbs its own column and
  arrives at the centre; it comes from column 0 and sits right of the line from column 3.
- A line has a detour only if its parent's branch goes on, a level at the parent is free and the
  line climbs past at least one row of cards. In the three repos no line without a detour breaks
  the order; another repo may have one, and `lab_check` reports it.

## Step 13: columns per mode; a tight fan shares its room; the engine's column tie-break

Ralph on 2026-11-10, on the gaps of step 8: **columns per mode.** `same-columns` is off by
default. Each mode is as narrow as its own rows allow, and its own rows decide which branch sits
inside. A card may change its column when the mode changes (jj 21 % of the cards, TWMS 30 %,
dart-intellij 1 %).

This gives up a guarantee of the product engine: the same lane and column in both modes
(docs/graph-layout.md §7.3, I8; Story 4.14). When the lab's rules move into the engine, I8 and
the joint packing go.

The denser columns showed two things. Each got a switch, on by default, code in `lib/lines.dart`:

- **A fan shares a tight place** (`tight-fan`; it needs `ports`): the lines of one card to one
  side keep 6 px between their tracks. Where the room does not hold them all, they lay on one
  level. Now they share the room evenly and come closer than 6 px. jj in Free at `pznposwy`: a
  card of another branch sits next to the fan of seven lines, and five of them lay on one level;
  now the seven are 3.6 px apart. It also separates the fans of ten lines in Compact's row gap.
- **Two lines of different cards do not share an upright stretch** (`tie-break`; it needs
  `ports`): the engine's column tie-break (docs/graph-layout.md §14, Ports). Where two lines run
  straight from their card edges on one x, the one that stays straight longer keeps its port; the
  other gives up the centre of its card edge and joins its side's fan. With columns per mode a
  branch often starts in a column right where another one ends: its fork line and the other's
  merge line shared the column's centre. The lab's version only moves a line away from the
  centre; no data set needs more.

Measured, crossings plus overlaps, before (same columns, step 12) → now:

| | dart-intellij | jj | TWMS |
|---|---|---|---|
| Free | 110 + 2 → 112 + 0 | 21 + 0 → 22 + 0 | 162 + 0 → 166 + 0 |
| Compact | 111 + 12 → 113 + 0 | 8 + 2 → 1 + 0 | 156 + 0 → 152 + 0 |
| Compact, no stacks | 111 + 12 → 113 + 0 | 43 + 2 → 10 + 0 | 169 + 0 → 158 + 1 |
| columns, Free / Compact | 11 / 11 → 11 / 11 | 13 / 13 → 11 / 12 | 11 / 11 → 11 / 10 |
| columns between parent and child, Free / Compact | 1171 → 1168 / 1119 | 460 → 418 / 407 | 853 → 826 / 770 |

One overlap is left, TWMS in Compact without stacks at `a96a9da`: a line that turns into a gutter
below a card and a merge run sit on one level for 124 px.

Ralph on 2026-11-10, after looking: a line that leaves the centre for the tie-break is an accepted
exception. The tight fan stays under watch; it may need another idea.

## Step 14: the rules live in the product

Ralph on 2026-11-10: the lab's line rules move into the engine (Story 4.18, docs/graph-layout.md
§14). `packages/zanshin_core/lib/src/graph_layout/router.dart` is now a port of `labLines` with every
switch on, and `App today` on the page is that router.

- `bin/lab_check.dart` runs its line rules on the product's lines too (`appLines` in `lib/scene.dart`);
  lines of one slot may share a port, as the product's shared entries do.
- `bin/lab_metrics.dart` prints the product's metrics next to the lab's.
- The product equals the lab on all three data sets in both modes, with and without stacks, but for
  the leftover of step 13: every run takes part in the tracks in the product, so TWMS in Compact
  without stacks has 159 crossings and 0 overlaps where the lab has 158 + 1 (a shared stretch hides a
  crossing, step 7). docs/graph-layout.md §14.6 lists every difference.

The lab stays the place to try the next rule: change `lib/`, look at the page, then amend the GLD.

## What the engine has and the lab does not

Carried over when the lab's rules moved into the engine (docs/graph-layout.md §14):

- shared entries: several dashed lines into one card with one parent share one port (a hidden
  merge);
- the full column tie-break: a line that loses at a fan slot moves one slot further out (the lab
  only moves a line away from the centre, step 13);
- the router's outputs the painter reads: the lines' points, the entry ports, the runs for the
  bridges, the reports;
- speed: the lab compares every pair of runs, scans every card of a column, and counts a
  detour's crossings against every other line.

The painter's rules need no change: the yellow line of `@`, dashes, the `//` marks and end stubs
of hidden history, bridges, hover and dim. They read the lines' points, whatever router made them.

## Later steps

Candidates:

- both sides of the main branch
- avoiding crossings
- bundles of lines in a gutter

## Rule log

Ralph approved the whole set on 2026-11-10: the lab with every switch at its default. These
rules move into the engine (epics.md, Stories 4.17 and 4.18). The step that added a rule holds
its measurements.

Columns (`lib/columns.dart`):

| Rule (switch) | Why | Step |
|---|---|---|
| The main branch is alone in column 0. | It is the line the eye follows; it must not drift. | 1 |
| A branch, a first-parent chain, keeps one column for its whole life. | A branch reads as one upright line. | 1 |
| A branch takes its column from its fork up to its last merge (`reserve-to-merge`). | Its fork line and its merge lines run straight in its own column. | 2 |
| The branch that ends first is placed first, then the shorter one; each takes the free column nearest to the main branch (`short-first`, `ends-first`). | A short branch sits inside, a long one runs around it. | 2, 9 |
| A side branch that merges back into its branch sits next to that branch (`dock-to-parent`). | A card sits near the lines it connects to. | 11 |
| Free and Compact each choose their own columns (`same-columns` off). | A gap whose reason shows only in the other mode reads as an error. | 8, 13 |

Lines (`lib/lines.dart`):

| Rule (switch) | Why | Step |
|---|---|---|
| A line turns into the gutter before a card in its way (`dodge`). | No line runs behind a card. | 1 |
| A horizontal run sits on a level that passes no card, 8 px from any card but its own (`free-level`). | The same. | 3, 10 |
| Runs that pass side by side share the room evenly, in the order in which they do not cross (`spread`). | Fewer crossings; lines do not hug each other or a card. | 4, 6 |
| One line of a card edge sits at the centre, the others fan out, every line on its own track (`ports`). | Every line can be followed from card to card. | 5 |
| A merge line bends at its parent when the parent's branch goes on (`bend-at-parent`). | The lines of a card bend at the card, in order. | 7 |
| Two lines never lie on top of each other; they cross instead (`no-overlap`). | A shared stretch hides a crossing and reads as a wrong connection. | 7 |
| A merge line may bend at its parent and climb next to its child's column, if it then crosses fewer lines (`fewer-crossings`). | Fewer crossings at the card. | 11 |
| The lines of a card turn in the order of their columns, always (`column-order`). | Another order looks unsorted. The line at the centre runs straight on and is no part of the order. | 12 |
| A fan shares a tight place evenly (`tight-fan`). | Else its lines lie on one level. Under watch: it may need another idea. | 13 |
| Two lines of different cards do not share an upright stretch; the shorter one leaves the centre (`tie-break`). | The engine's rule. A lone line off the centre is an accepted exception. | 13 |

Not approved, switched off: `fewest-skipped` (step 9) and `same-columns` (steps 8 and 13).
