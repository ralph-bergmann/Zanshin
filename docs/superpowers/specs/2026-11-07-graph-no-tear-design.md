# Free layout without a tear — design

Approved by Ralph on 2026-11-07 (console session). Story 10.31 follow-up.

## Intent

Ralph found the Free layout's break (the tear, DS `GraphBreak`) on `dart-intellij-third-party`, under a collapsed
stack, labelled "4 years · Feb 2021 – Mar 2025". It read as four years without a change, while the stack holds 486
changes from those years. The tear was meant to save scrolling past screens of lines without cards, and it should only
shorten real pauses. A stack sums up cards. It must not create a pause. The goal: the graph never suggests that
nothing changed where things did.

## Facts

- Free draws a real pause at most 3 pitches tall: `freeGap` ≤ 48 units, and `freeStep` is at least one pitch across a
  day change (`packages/zanshin_core/lib/src/graph_layout/layout_engine.dart:54-74`).
- A card-free stretch taller than that only comes from folded stack members. A collapsed stack sits at its newest
  member's row and keeps its hidden members' time below it.
- The longest real pause on `dart-intellij-third-party` is 75 days.

## Approaches

- **A:** keep a tear, but only for real pauses of 2 weeks or more, never under a stack.
- **B:** no tear at all.

Ralph chose **B**.

## Design (B)

1. **No tear.** The torn strip, the span label and the minimap zigzag go, in the app, the prototype and the DS.
   `GraphBreak` is deleted.
2. **The shortening stays, invisible.** A card-free stretch taller than 3 pitches shrinks to 1½ pitches card to card.
   It was 8 pitches before. Only folded members make such a stretch. This was Claude's call, approved by Ralph: it
   follows from "a stack creates no pause".
3. **Day and year labels stay** inside a shortened stretch. Before, they dropped out.
4. **The stack card always shows its period.**
   - First the full form: "Feb 14, 2021 – Mar 28, 2025".
   - If that does not fit, months: "Feb 2021 – Mar 2025" (the old range form).
   - If that does not fit either, it is cut with "…".
   - The authors yield first, as before.
5. **Records:** a dated note under Story 10.31 (`epics.md`), `deferred-work.md`, a `DESIGN-SYSTEM-SYNC.md` entry,
   and the DS republished.

## Non-goals

- The layout engine (`zanshin_core`) stays unchanged. Folded members keep their rows there, and the app shortens them
  away.
- Compact stays unchanged.

## Verification

- The tests.
- Marionette in the running app at the spot of Ralph's screenshot on `dart-intellij-third-party`.
- Marionette in the catalogue, "Graph › Minimap › Long history", compared with the reworked DS card.
- `cargo make test`.

## Left to the builder

- The names.
- The exact yield code.
- The test widths.
