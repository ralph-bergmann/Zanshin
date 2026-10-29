---
name: design-artifacts
description: Use when the Zanshin design system or the app design changes, or Ralph asks to update, publish or back up them — e.g. "DS aktualisieren", "Design-System veröffentlichen", "übernimm das aus dem Design ins DS", "Design sichern". Covers the repo-kept design system, its Design System artifact on claude.ai and the Design canvases that use it.
---

# Design system and designs after Claude Design

Standalone Claude Design (claude.ai/design) closes 2026-12-14. Since 2026-10-29 the work lives here:

| What | Source of truth | Published as |
|---|---|---|
| Design system: tokens, components, guidelines, brand book, UI kit | `_bmad-output/implementation-artifacts/design_system/` (this repo; Claude Code edits it in place — there are no more re-downloads) | Design System artifact https://claude.ai/artifact/J5iSiy8cS6Q1EXa44g945d — read-only page (`"editing": "code"`), namespace `ZanshinDesignSystem_a33847` |
| App design: the clickable prototype (the floating client) | `_bmad-output/implementation-artifacts/design/` — `JJ Desktop Client Floating.html` and its `.jsx`/`.css`; Claude Code edits it in place, exactly as Claude Design did (F) | the Browser pane via `.claude/launch.json` → `design-preview` |
| App design: static screen overview (16 boards a–k, state of 2026-10-26) | Design canvas https://claude.ai/artifact/6sAzL5mDcVpWXevbTcempu | itself — a picture, not maintained alongside the prototype; rebuild it when Ralph asks |

Flutter reads `design_system/` directly (`packages/zanshin_ui/test/design/css_token_reader.dart`, `crates/xtask/src/tasks/gate_plan.rs`, specs), so its layout stays as it is: `tokens/*.css`, `components/<group>/<Comp>.jsx|.d.ts|.prompt.md`, `_ds_bundle.js`, `readme.md` (brand book, "Synced through #N").

Canvases with the DS installed (keep this list current): `6sAzL5mDcVpWXevbTcempu` (Zanshin app design).

## A. Publish the DS after a change in `design_system/`

1. `read` `project/design-system.json` from the DS artifact (it saves a copy; note the path).
2. `python3 -I .claude/skills/design-artifacts/build_ds.py _bmad-output/implementation-artifacts/design_system <scratchpad>/ds <saved design-system.json>` — writes `<scratchpad>/ds/project/…`, prints the files that still need an upload and the publish map.
3. New or changed logos/icons the script lists: upload them first (`publish`, `url` = the DS, `asset: true`, `file_paths`) and add each `{name, blob, size, type}` record to the index's `assetGroups.<Logos|Icons>.files` and `order`.
4. Copy the index to `<scratchpad>/ds/project/design-system.json`; keep every key (`"editing": "code"` stays), set `lastChange` (`by` Ralph Bergmann, `at` now, `via` "Claude Code · Zanshin repo", a one-line `note`).
5. ONE publish: `url` = the DS, `root` = `<scratchpad>/ds`, `file_path` = the index, `files` = the printed map (send all of it, or only the changed paths). `.jsx` and `.d.ts` go as `text/plain` (the map already says so). A refused publish: re-read the index, redo step 4, publish again.
6. Then B for every canvas in the list above.

## B. Update the DS on a canvas

One publish to the canvas: `files` copies from the DS server-side — `project/ds/zanshin/tokens.json`, `…/components/bundle.js`, `…/components/bundle.css`, `…/fonts/*.woff2`, each `{"artifact": "https://claude.ai/artifact/J5iSiy8cS6Q1EXa44g945d", "path": "project/<same path>"}` — plus `project/canvas.json` with its `designSystems` record's `version` and `copiedAt` updated (read the canvas's `canvas.json` right before; change nothing else). Artboards load `ds/zanshin/components/bundle.css` and `ds/zanshin/components/bundle.js` (bundle.css carries every token; no tokens.css is published).

## C. Something new in the design belongs in the DS

Make the change in `design_system/` (CSS tokens, the component's `.jsx` + `.d.ts` + `.prompt.md`, `readme.md`), add a dated line to the readme's Sync section saying what came from the prototype or the canvas, then A and B. The rule of the system still holds: the DS leads, designs use its components.

## D. Back up a canvas into the repo (replaces the ZIP download)

`list` the canvas's files (`scope: "files"`), `read` every `project/…` path (`paths`, up to 256 per call) and write them to `_bmad-output/implementation-artifacts/design-canvas/<canvas name>/` (keep the paths below `project/`; skip `project/ds/`, it is a copy of the DS). Uploaded images (`/_blob/<id>`): `read` the id as `path`. Commit only when Ralph asks.

## E. Changing a component's code

`_ds_bundle.js` is the compiled bundle (format 4, header JSON on line 1, then one `// components/<group>/<Comp>.jsx` + `try { (() => { … })(); } catch …` block per source file, JSX already turned into `React.createElement`, exports assigned to the namespace). No build tool is installed: after editing a `.jsx`, rewrite that file's block in `_ds_bundle.js` by hand to match (look at a neighbouring block for the pattern) and add a new component's name to the header's `components` list. Never leave a literal `</script` or `<!--` in it (the script refuses).

## F. Changing the app design (the click dummy)

Edit the prototype in `design/` (`app-float.jsx`, `graph-*.jsx`, `inspector.jsx`, `settings.jsx`, `float.css`, …; `design/CLAUDE.md` holds the project's own notes), then show it: `preview_start` `design-preview` and open `JJ Desktop Client Floating.html`. A change that belongs to the system (a token, a component, a rule) also goes into `design_system/` with a numbered entry in `design/DESIGN-SYSTEM-SYNC.md`, then A — the same two-step habit as in Claude Design, without the ZIPs. The old copies of the prototype (`JJ Desktop Client.html`, `archive/`, studies) stay reference only.

## Pitfalls

- `x-import` of `GraphEdge` inside an `<svg>` fails in a `.dc.html` artboard; draw graph edges another way.
- The DS page shows no editor (read-only on purpose): token or component edits made there would split from the repo.
- `tokens.json` is a mirror for the editor's Theme menu; the values that render come from `components/bundle.css`. Both are generated from the same CSS by the script.
