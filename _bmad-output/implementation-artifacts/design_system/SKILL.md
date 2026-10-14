---
name: zanshin-design
description: Use this skill to generate well-branded interfaces and assets for Zanshin (a desktop client for the Jujutsu / jj version control system), either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the readme.md file within this skill, and explore the other available files.

If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. If working on production code, you can copy assets and read the rules here to become an expert in designing with this brand.

If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some questions, and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

Quick orientation:
- `styles.css` is the single stylesheet entry (tokens + webfonts + component CSS). Night (indigo) is the default theme; `data-theme="light"` on `<html>` switches to paper.
- `components/**` — React primitives (`.jsx` + `.d.ts` + `.prompt.md`). `ui_kits/desktop/` composes them into the floating client: graph (Free · Compact, day axis, the client's line router), search field, inspector, drag-to-rebase, projects, settings, jj log configurations.
- Rules that matter most: the graph owns the window and all chrome floats on glass islands 12px from the edges; gold only for `@` and the one primary action, moon for selection/focus/controls; JetBrains Mono for anything jj prints; sentence-case verbs with the exact jj command in the tooltip/footer; `$` marks a jj log variant that draws the graph; one graph line per parent → child pair with its own exit and entry (`GraphPorts`); no emoji; every edit offers Undo.
- Brand mark: Nami (`assets/app-icon/zanshin-icon-nami-indigo.svg`, `NamiMark`); wordmark SVGs in `assets/`. Never redraw them; the ensō is retired.
